//
//  SpectrogramEngine.swift
//  SimpleSpectr
//
//  Decodes an audio file and computes a spectrogram image (STFT via Accelerate).
//

import Foundation
import AVFoundation
import Accelerate
import CoreGraphics

/// Result of a spectrogram computation. The CGImage has high frequencies at the
/// top and low frequencies at the bottom; columns advance in time left → right.
struct SpectrogramResult: @unchecked Sendable {
    let image: CGImage
    let duration: Double          // seconds
    let sampleRate: Double        // Hz
    let maxFrequency: Double      // Hz (Nyquist)
    let fftSize: Int
    let columns: Int
    let bins: Int
    let minDB: Double             // dB value mapped to the bottom of the color scale
    let maxDB: Double             // dB value mapped to the top of the color scale
    /// Column-major dB magnitudes: `magnitudes[column * bins + bin]`, bin 0 = lowest freq.
    let magnitudes: [Float]

    /// dB magnitude at a fractional position in the plot (0…1, origin bottom-left).
    /// Returns the value plus the resolved time/frequency for a hover readout.
    func sample(fractionX: Double, fractionY: Double) -> (time: Double, frequency: Double, db: Double)? {
        guard columns > 0, bins > 0 else { return nil }
        let fx = min(max(fractionX, 0), 1)
        let fy = min(max(fractionY, 0), 1)
        let column = min(Int(fx * Double(columns)), columns - 1)
        let bin = min(Int(fy * Double(bins)), bins - 1)
        let db = Double(magnitudes[column * bins + bin])
        let frequency = Double(bin) * sampleRate / Double(fftSize)
        let time = fx * duration
        return (time, frequency, db)
    }
}

enum SpectrogramError: LocalizedError {
    case cannotOpen(String)
    case emptyAudio
    case invalidFFTSize
    case fftSetupFailed
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let why): return "Не удалось открыть аудиофайл: \(why)"
        case .emptyAudio:          return "Файл не содержит аудиоданных."
        case .invalidFFTSize:      return "Размер окна БПФ должен быть степенью двойки."
        case .fftSetupFailed:      return "Не удалось инициализировать БПФ."
        case .renderFailed:        return "Не удалось построить изображение спектрограммы."
        }
    }
}

enum SpectrogramEngine {

    /// Compute a spectrogram for the audio file at `url`.
    /// - Parameters:
    ///   - fftSize: FFT window size (power of two). 2048 → 1024 frequency bins.
    ///   - maxColumns: upper bound on the number of time columns (bounds compute/memory).
    nonisolated static func generate(url: URL,
                                     fftSize: Int = 2048,
                                     maxColumns: Int = 2000) throws -> SpectrogramResult {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard fftSize > 0, fftSize & (fftSize - 1) == 0 else { throw SpectrogramError.invalidFFTSize }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw SpectrogramError.cannotOpen(error.localizedDescription)
        }

        let format = file.processingFormat // Float32, non-interleaved
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let totalFrames = Int(file.length)
        guard totalFrames >= fftSize, channelCount > 0 else { throw SpectrogramError.emptyAudio }

        let log2n = vDSP_Length(fftSize.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw SpectrogramError.fftSetupFailed
        }
        defer { vDSP_destroy_fftsetup(setup) }

        let bins = fftSize / 2
        let total = totalFrames
        // Hop so that we land near (but not above) maxColumns, never finer than fftSize/4.
        let minHop = max(1, fftSize / 4)
        let neededHop = Int(ceil(Double(total - fftSize) / Double(max(1, maxColumns - 1))))
        let hop = max(minHop, neededHop)
        let columns = max(1, (total - fftSize) / hop + 1)

        // Hann window and its coherent sum (used to normalize FFT output to amplitude).
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        var winSum: Float = 0
        vDSP_sve(window, 1, &winSum, vDSP_Length(fftSize))
        let twoOverWinSum: Float = 2.0 / winSum // one-sided spectrum, window-corrected

        // Scratch buffers for the real FFT (split-complex packing), hoisted out of the loop.
        var realp = [Float](repeating: 0, count: bins)
        var imagp = [Float](repeating: 0, count: bins)
        var windowed = [Float](repeating: 0, count: fftSize)
        var mags = [Float](repeating: 0, count: bins)

        // Column-major magnitude grid in dB: magnitudes[col * bins + bin].
        var magnitudes = [Float](repeating: 0, count: columns * bins)
        var globalMax: Float = -.greatestFiniteMagnitude

        // Decode on the fly through a sequential mono source so the whole file is
        // never materialized in memory.
        var source = MonoSource(file: file, channelCount: channelCount)
        var windowSamples = [Float](repeating: 0, count: fftSize)
        _ = try source.fill(into: &windowSamples, offset: 0, count: fftSize)

        for col in 0..<columns {
            if col > 0 {
                if hop < fftSize {
                    // Overlapping windows: slide the buffer left by `hop`, refill the tail.
                    let keep = fftSize - hop
                    for i in 0..<keep { windowSamples[i] = windowSamples[i + hop] }
                    _ = try source.fill(into: &windowSamples, offset: keep, count: hop)
                } else {
                    // Non-overlapping windows for very long files: skip the gap, read fresh.
                    _ = try source.discard(count: hop - fftSize)
                    _ = try source.fill(into: &windowSamples, offset: 0, count: fftSize)
                }
            }
            try Task.checkCancellation()

            // Apply window into `windowed`.
            vDSP_vmul(windowSamples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(bins))
                        }
                    }
                    // Forward real FFT.
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                    // With fft_zrip, slot 0 packs DC (realp[0]) and Nyquist (imagp[0]).
                    // Drop Nyquist so it does not contaminate the DC magnitude.
                    ip.baseAddress![0] = 0

                    // Magnitude (sqrt of squared) into `mags`.
                    vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(bins))
                }
            }

            // Normalize to amplitude: factor 2 for the one-sided spectrum, divided by the
            // window's coherent sum. DC has no spectral mirror, so it is not doubled.
            var k = twoOverWinSum
            vDSP_vsmul(mags, 1, &k, &mags, 1, vDSP_Length(bins))
            mags[0] *= 0.5

            // Convert to dB (20*log10), guarding against log(0).
            var ref: Float = 1.0
            vDSP_vdbcon(mags, 1, &ref, &mags, 1, vDSP_Length(bins), 1)

            let colBase = col * bins
            for b in 0..<bins {
                let v = mags[b]
                magnitudes[colBase + b] = v
                if v > globalMax { globalMax = v }
            }
        }

        // 3. Map dB → color. Use a fixed dynamic range below the peak.
        let dynamicRange: Float = 90
        let peak = globalMax.isFinite ? globalMax : 0
        let maxDB = peak
        let minDB = peak - dynamicRange
        let image = try makeImage(magnitudes: magnitudes,
                                  columns: columns,
                                  bins: bins,
                                  minDB: minDB,
                                  maxDB: maxDB)

        return SpectrogramResult(image: image,
                                 duration: Double(total) / sampleRate,
                                 sampleRate: sampleRate,
                                 maxFrequency: sampleRate / 2,
                                 fftSize: fftSize,
                                 columns: columns,
                                 bins: bins,
                                 minDB: Double(minDB),
                                 maxDB: Double(maxDB),
                                 magnitudes: magnitudes)
    }

    // MARK: - Image generation

    private nonisolated static func makeImage(magnitudes: [Float],
                                              columns: Int,
                                              bins: Int,
                                              minDB: Float,
                                              maxDB: Float) throws -> CGImage {
        let width = columns
        let height = bins
        let invRange = 1.0 / max(1e-6, (maxDB - minDB))

        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for col in 0..<columns {
                for row in 0..<height {
                    // row 0 = top = highest frequency → bin index (bins - 1 - row)
                    let bin = bins - 1 - row
                    let db = magnitudes[col * bins + bin]
                    var t = (db - minDB) * invRange
                    if !t.isFinite { t = 0 }
                    if t < 0 { t = 0 } else if t > 1 { t = 1 }
                    let (r, g, b) = Colormap.infernoLUT(Int(t * 255))
                    let offset = (row * width + col) * 4
                    p[offset + 0] = r
                    p[offset + 1] = g
                    p[offset + 2] = b
                    p[offset + 3] = 255
                }
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: pixels as CFData) else {
            throw SpectrogramError.renderFailed
        }
        guard let image = CGImage(width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bitsPerPixel: 32,
                                  bytesPerRow: width * 4,
                                  space: colorSpace,
                                  bitmapInfo: bitmapInfo,
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: true,
                                  intent: .defaultIntent) else {
            throw SpectrogramError.renderFailed
        }
        return image
    }
}

// MARK: - Sequential mono decoder

/// Reads an `AVAudioFile` forward, down-mixing to mono, and hands out samples on
/// demand. Only a small chunk is ever held in memory, so long files don't blow up
/// the heap.
private struct MonoSource {
    private let file: AVAudioFile
    private let channelCount: Int
    private let chunkFrames: AVAudioFrameCount
    private let buffer: AVAudioPCMBuffer

    private var pending: [Float] = []
    private var pendingOffset = 0
    private var eof = false

    init(file: AVAudioFile, channelCount: Int) {
        self.file = file
        self.channelCount = channelCount
        self.chunkFrames = 1 << 18 // 262144 frames per read
        self.buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 18)!
    }

    /// Copy up to `count` samples into `dst[offset..<]`. Returns the number copied.
    mutating func fill(into dst: inout [Float], offset: Int, count: Int) throws -> Int {
        var written = 0
        while written < count {
            if pendingOffset >= pending.count {
                if eof { break }
                try decodeNextChunk()
                if pendingOffset >= pending.count { break }
            }
            let take = min(count - written, pending.count - pendingOffset)
            for i in 0..<take {
                dst[offset + written + i] = pending[pendingOffset + i]
            }
            pendingOffset += take
            written += take
        }
        return written
    }

    /// Advance the read position by `count` samples without copying them.
    mutating func discard(count: Int) throws -> Int {
        var discarded = 0
        while discarded < count {
            if pendingOffset >= pending.count {
                if eof { break }
                try decodeNextChunk()
                if pendingOffset >= pending.count { break }
            }
            let take = min(count - discarded, pending.count - pendingOffset)
            pendingOffset += take
            discarded += take
        }
        return discarded
    }

    /// Read one chunk from the file into `pending`. Safe at EOF: returns without
    /// throwing, leaving `pending` empty. `read(into:)` throws at EOF, so the loop
    /// is driven by `framePosition < length` and reads `min(chunk, remaining)`.
    private mutating func decodeNextChunk() throws {
        guard !eof, file.framePosition < file.length else {
            eof = true
            return
        }
        let remaining = file.length - file.framePosition
        let toRead = AVAudioFrameCount(min(Int64(chunkFrames), remaining))
        buffer.frameLength = 0
        do {
            try file.read(into: buffer, frameCount: toRead)
        } catch {
            eof = true
            throw SpectrogramError.cannotOpen(error.localizedDescription)
        }
        let frames = Int(buffer.frameLength)
        if frames == 0 { eof = true; return }
        guard let channels = buffer.floatChannelData else { eof = true; return }

        pending.removeAll(keepingCapacity: true)
        pendingOffset = 0
        if channelCount == 1 {
            let p = channels[0]
            pending.append(contentsOf: UnsafeBufferPointer(start: p, count: frames))
        } else {
            let inv = 1.0 / Float(channelCount)
            pending = [Float](repeating: 0, count: frames)
            for ch in 0..<channelCount {
                vDSP_vadd(pending, 1, channels[ch], 1, &pending, 1, vDSP_Length(frames))
            }
            var s = inv
            vDSP_vsmul(pending, 1, &s, &pending, 1, vDSP_Length(frames))
        }
    }
}
