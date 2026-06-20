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
    case fftSetupFailed

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let why): return "Не удалось открыть аудиофайл: \(why)"
        case .emptyAudio:          return "Файл не содержит аудиоданных."
        case .fftSetupFailed:      return "Не удалось инициализировать БПФ."
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

        // 1. Decode to a mono Float buffer.
        let (samples, sampleRate) = try decodeMono(url: url)
        guard samples.count >= fftSize else { throw SpectrogramError.emptyAudio }

        // 2. STFT configuration.
        let log2n = vDSP_Length(log2(Double(fftSize)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw SpectrogramError.fftSetupFailed
        }
        defer { vDSP_destroy_fftsetup(setup) }

        let bins = fftSize / 2
        let total = samples.count
        // Hop so that we land near (but not above) maxColumns, never finer than fftSize/4.
        let minHop = max(1, fftSize / 4)
        let neededHop = Int(ceil(Double(total - fftSize) / Double(max(1, maxColumns - 1))))
        let hop = max(minHop, neededHop)
        let columns = max(1, (total - fftSize) / hop + 1)

        // Hann window.
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        // Scratch buffers for the real FFT (split-complex packing).
        var realp = [Float](repeating: 0, count: bins)
        var imagp = [Float](repeating: 0, count: bins)
        var windowed = [Float](repeating: 0, count: fftSize)

        // Column-major magnitude grid in dB: magnitudes[col * bins + bin].
        var magnitudes = [Float](repeating: 0, count: columns * bins)
        var globalMax: Float = -.greatestFiniteMagnitude

        let scale = 1.0 / Float(fftSize) // normalize FFT magnitude

        samples.withUnsafeBufferPointer { src in
            for col in 0..<columns {
                let start = col * hop
                // Apply window into `windowed`.
                vDSP_vmul(src.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

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

                        // Magnitude (sqrt of squared) into the column.
                        var mags = [Float](repeating: 0, count: bins)
                        vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(bins))
                        var s = scale
                        vDSP_vsmul(mags, 1, &s, &mags, 1, vDSP_Length(bins))

                        // Convert to dB (20*log10), guarding against log(0).
                        var ref: Float = 1.0
                        vDSP_vdbcon(mags, 1, &ref, &mags, 1, vDSP_Length(bins), 1) // 1 → 20*log10

                        for b in 0..<bins {
                            let v = mags[b]
                            magnitudes[col * bins + b] = v
                            if v > globalMax { globalMax = v }
                        }
                    }
                }
            }
        }

        // 3. Map dB → color. Use a fixed dynamic range below the peak.
        let dynamicRange: Float = 90
        let maxDB = globalMax
        let minDB = maxDB - dynamicRange
        let image = makeImage(magnitudes: magnitudes,
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

    // MARK: - Decoding

    /// Decode any Core Audio–supported file to a mono Float array + sample rate.
    private nonisolated static func decodeMono(url: URL) throws -> ([Float], Double) {
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
        guard totalFrames > 0, channelCount > 0 else { throw SpectrogramError.emptyAudio }

        var mono = [Float]()
        mono.reserveCapacity(totalFrames)

        let chunkFrames: AVAudioFrameCount = 1 << 18 // 262144 frames per read
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw SpectrogramError.emptyAudio
        }

        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let toRead = AVAudioFrameCount(min(Int64(chunkFrames), remaining))
            buffer.frameLength = 0
            do {
                try file.read(into: buffer, frameCount: toRead)
            } catch {
                throw SpectrogramError.cannotOpen(error.localizedDescription)
            }
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let channels = buffer.floatChannelData else { break }

            if channelCount == 1 {
                let p = channels[0]
                mono.append(contentsOf: UnsafeBufferPointer(start: p, count: frames))
            } else {
                let inv = 1.0 / Float(channelCount)
                var mixed = [Float](repeating: 0, count: frames)
                for ch in 0..<channelCount {
                    vDSP_vadd(mixed, 1, channels[ch], 1, &mixed, 1, vDSP_Length(frames))
                }
                var s = inv
                vDSP_vsmul(mixed, 1, &s, &mixed, 1, vDSP_Length(frames))
                mono.append(contentsOf: mixed)
            }
        }

        return (mono, sampleRate)
    }

    // MARK: - Image generation

    private nonisolated static func makeImage(magnitudes: [Float],
                                              columns: Int,
                                              bins: Int,
                                              minDB: Float,
                                              maxDB: Float) -> CGImage {
        let width = columns
        let height = bins
        let invRange = 1.0 / max(1e-6, (maxDB - minDB))

        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        for col in 0..<columns {
            for row in 0..<height {
                // row 0 = top = highest frequency → bin index (bins - 1 - row)
                let bin = bins - 1 - row
                let db = magnitudes[col * bins + bin]
                var t = (db - minDB) * invRange
                if t < 0 { t = 0 } else if t > 1 { t = 1 }
                let (r, g, b) = Colormap.inferno(t)
                let offset = (row * width + col) * 4
                pixels[offset + 0] = r
                pixels[offset + 1] = g
                pixels[offset + 2] = b
                pixels[offset + 3] = 255
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: width * 4,
                       space: colorSpace,
                       bitmapInfo: bitmapInfo,
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: true,
                       intent: .defaultIntent)!
    }
}
