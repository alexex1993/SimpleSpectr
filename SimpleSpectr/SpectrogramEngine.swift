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
    /// Always stored on the *linear* bin grid regardless of `frequencyScale`, so the
    /// hover readout and a scale re-render stay exact without re-decoding audio.
    let magnitudes: [Float]
    let frequencyScale: FrequencyScale
    let minDisplayedFrequency: Double   // Hz at the bottom of the plot (log axis anchor)

    /// Per-column waveform envelope: the min and max raw sample within each STFT
    /// frame (length == columns). Drives the overview waveform lane, lined up 1:1
    /// with the spectrogram's time columns.
    let waveformMin: [Float]
    let waveformMax: [Float]

    /// Frequency-axis mapping the image and axes were rendered with.
    var frequencyAxis: FrequencyAxis {
        FrequencyAxis(scale: frequencyScale,
                      sampleRate: sampleRate,
                      fftSize: fftSize,
                      bins: bins,
                      minFrequency: minDisplayedFrequency,
                      maxFrequency: maxFrequency)
    }

    /// dB magnitude at a fractional position in the plot (0…1, origin bottom-left).
    /// Returns the value plus the resolved time/frequency for a hover readout.
    func sample(fractionX: Double, fractionY: Double) -> (time: Double, frequency: Double, db: Double)? {
        guard columns > 0, bins > 0 else { return nil }
        let fx = min(max(fractionX, 0), 1)
        let fy = min(max(fractionY, 0), 1)
        let column = min(Int(fx * Double(columns)), columns - 1)
        let axis = frequencyAxis
        let bin = axis.bin(forFraction: fy)
        let db = Double(magnitudes[column * bins + bin])
        let frequency = axis.frequency(forFraction: fy)
        let time = fx * duration
        return (time, frequency, db)
    }

    /// Copy keeping the magnitudes but swapping the presented image and frequency
    /// axis (used when re-rendering with a new palette or a new frequency scale).
    func rerendered(image: CGImage,
                    scale: FrequencyScale? = nil,
                    minDisplayedFrequency: Double? = nil) -> SpectrogramResult {
        SpectrogramResult(image: image,
                          duration: duration,
                          sampleRate: sampleRate,
                          maxFrequency: maxFrequency,
                          fftSize: fftSize,
                          columns: columns,
                          bins: bins,
                          minDB: minDB,
                          maxDB: maxDB,
                          magnitudes: magnitudes,
                          frequencyScale: scale ?? frequencyScale,
                          minDisplayedFrequency: minDisplayedFrequency ?? self.minDisplayedFrequency,
                          waveformMin: waveformMin,
                          waveformMax: waveformMax)
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
        case .cannotOpen(let why): return L("error.cannotOpen", why)
        case .emptyAudio:          return L("error.emptyAudio")
        case .invalidFFTSize:      return L("error.invalidFFTSize")
        case .fftSetupFailed:      return L("error.fftSetupFailed")
        case .renderFailed:        return L("error.renderFailed")
        }
    }
}

enum SpectrogramEngine {

    /// Compute a spectrogram for the audio file at `url`.
    /// - Parameters:
    ///   - fftSize: FFT window size (power of two). 2048 → 1024 frequency bins.
    ///   - overlapPercent: STFT overlap in percent (0…87.5). Larger values give
    ///     smoother time detail; the hop is `fftSize * (1 - overlap/100)`.
    ///   - windowFunction: window applied to each frame before the FFT.
    ///   - frequencyScale: presentation of the rendered image's frequency axis.
    ///   - maxColumns: upper bound on the number of time columns (bounds compute/memory).
    ///   - palette: colormap used to map dB → color.
    nonisolated static func generate(url: URL,
                                     fftSize: Int = 2048,
                                     overlapPercent: Double = 75,
                                     windowFunction: WindowFunction = .hann,
                                     frequencyScale: FrequencyScale = .linear,
                                     maxColumns: Int = 2000,
                                     palette: Palette = .inferno) throws -> SpectrogramResult {
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
        // Hop from the requested overlap; clamp to the column cap so long files
        // never blow up memory (effective overlap then drops below the request).
        let clampedOverlap = min(max(overlapPercent, 0), 87.5)
        let desiredHop = max(1, Int((Double(fftSize) * (1.0 - clampedOverlap / 100.0)).rounded()))
        let neededHop = Int(ceil(Double(total - fftSize) / Double(max(1, maxColumns - 1))))
        let hop = max(desiredHop, neededHop)
        let columns = max(1, (total - fftSize) / hop + 1)

        // Window (user-selectable) and its coherent sum, used to normalize FFT
        // output back to physical amplitude (one-sided spectrum factor 2 applied).
        let window = windowFunction.generate(size: fftSize)
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

        // Per-column overview waveform envelope.
        var waveMin = [Float](repeating: 0, count: columns)
        var waveMax = [Float](repeating: 0, count: columns)

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

            // Overview waveform: peak min/max of the raw samples in this frame.
            var frameMin: Float = 0
            var frameMax: Float = 0
            vDSP_minv(windowSamples, 1, &frameMin, vDSP_Length(fftSize))
            vDSP_maxv(windowSamples, 1, &frameMax, vDSP_Length(fftSize))
            waveMin[col] = frameMin
            waveMax[col] = frameMax

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
        let axis = FrequencyAxis.make(scale: frequencyScale,
                                      sampleRate: sampleRate,
                                      fftSize: fftSize,
                                      bins: bins)
        let image = try renderImage(magnitudes: magnitudes,
                                    columns: columns,
                                    bins: bins,
                                    minDB: minDB,
                                    maxDB: maxDB,
                                    palette: palette,
                                    frequencyAxis: axis)

        return SpectrogramResult(image: image,
                                 duration: Double(total) / sampleRate,
                                 sampleRate: sampleRate,
                                 maxFrequency: sampleRate / 2,
                                 fftSize: fftSize,
                                 columns: columns,
                                 bins: bins,
                                 minDB: Double(minDB),
                                 maxDB: Double(maxDB),
                                 magnitudes: magnitudes,
                                 frequencyScale: frequencyScale,
                                 minDisplayedFrequency: axis.minFrequency,
                                 waveformMin: waveMin,
                                 waveformMax: waveMax)
    }

    // MARK: - Image generation

    /// Map a dB magnitude grid into a `CGImage` using the given colormap.
    /// Exposed so a loaded spectrogram can be re-rendered (e.g. when the user
    /// changes palette or frequency scale) without re-decoding the audio.
    ///
    /// `magnitudes` is always the linear-bin grid. When `frequencyAxis.scale` is
    /// `.logarithmic`, each output row is sampled at the matching frequency with
    /// linear interpolation between adjacent bins, warping the image to the log
    /// axis so it lines up with the on-screen note labels.
    nonisolated static func renderImage(magnitudes: [Float],
                                        columns: Int,
                                        bins: Int,
                                        minDB: Float,
                                        maxDB: Float,
                                        palette: Palette = .inferno,
                                        frequencyAxis: FrequencyAxis? = nil) throws -> CGImage {
        let width = columns
        let height = bins
        let invRange = 1.0 / max(1e-6, (maxDB - minDB))
        let lut = palette.lut
        let logScale = frequencyAxis?.scale == .logarithmic

        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for col in 0..<columns {
                let colBase = col * bins
                for row in 0..<height {
                    // row 0 = top = highest frequency → fraction 1 at top, 0 at bottom.
                    let db: Float
                    if logScale, let axis = frequencyAxis, height > 1 {
                        let fracY = Double(height - 1 - row) / Double(height - 1)
                        let freq = axis.frequency(forFraction: fracY)
                        let fbin = freq * Double(axis.fftSize) / axis.sampleRate
                        db = Self.sampleLinear(magnitudes, colBase: colBase, bins: bins, at: fbin)
                    } else {
                        // Linear 1:1 — row 0 (top) → highest bin.
                        let bin = bins - 1 - row
                        db = magnitudes[colBase + bin]
                    }
                    var t = (db - minDB) * invRange
                    if !t.isFinite { t = 0 }
                    if t < 0 { t = 0 } else if t > 1 { t = 1 }
                    let (r, g, b) = lut[Int(t * 255)]
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

    /// Linearly interpolate the dB magnitude at a fractional bin index for one
    /// column (colBase = column * bins). Used by the log-frequency resample.
    nonisolated private static func sampleLinear(_ magnitudes: [Float],
                                                 colBase: Int,
                                                 bins: Int,
                                                 at fractionalBin: Double) -> Float {
        let lo = max(0, min(bins - 1, Int(fractionalBin)))
        let hi = min(bins - 1, lo + 1)
        let frac = Float(max(0, min(1, fractionalBin - Double(lo))))
        let a = magnitudes[colBase + lo]
        let b = magnitudes[colBase + hi]
        return a + (b - a) * frac
    }
}

// MARK: - Sequential mono decoder

/// Reads an `AVAudioFile` forward, down-mixing to mono, and hands out samples on
/// demand. Only a small chunk is ever held in memory, so long files don't blow up
/// the heap.
nonisolated private struct MonoSource {
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
