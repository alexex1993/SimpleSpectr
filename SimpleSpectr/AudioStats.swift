//
//  AudioStats.swift
//  SimpleSpectr
//
//  Time-domain amplitude statistics over a selected time range: RMS, sample
//  peak, true peak (4× oversampled) and integrated loudness (ITU-R BS.1770
//  K-weighting + gating). Reads the raw samples for the range directly from the
//  file so the numbers match the source, independent of the STFT grid.
//

import Foundation
import AVFoundation

/// Amplitude measurements for a time selection. dB values are dBFS (0 dB = full
/// scale); `truePeakDBTP` is dBTP (oversampled) and `lufs` is LUFS. Any field is
/// `NaN` when it cannot be computed (e.g. silence, or a selection too short for a
/// loudness block).
struct AmplitudeStats: Sendable {
    let rmsDBFS: Double
    let peakDBFS: Double
    let truePeakDBTP: Double
    let lufs: Double
    let channelCount: Int
    let frameCount: Int
}

enum AudioStatsError: Error { case emptyRange }

/// Computes `AmplitudeStats` for a `[startTime, endTime)` slice of an audio file.
/// Pure / `nonisolated` so it runs off the main actor (see `MeasurementModel`).
nonisolated enum AudioStatsAnalyzer {

    static func analyze(url: URL, startTime: Double, endTime: Double) throws -> AmplitudeStats {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat       // Float32, non-interleaved
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let total = Int(file.length)
        guard channelCount > 0, total > 0, sampleRate > 0 else { throw AudioStatsError.emptyRange }

        let lo = max(0.0, min(startTime, endTime))
        let hi = min(Double(total) / sampleRate, max(startTime, endTime))
        let startFrame = max(0, min(total, Int((lo * sampleRate).rounded())))
        let endFrame = max(0, min(total, Int((hi * sampleRate).rounded())))
        let count = endFrame - startFrame
        guard count > 0 else { throw AudioStatsError.emptyRange }

        // Read the range into per-channel float buffers.
        var channels = [[Float]](repeating: [Float](repeating: 0, count: count), count: channelCount)
        file.framePosition = AVAudioFramePosition(startFrame)
        let chunkCap: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkCap) else {
            throw AudioStatsError.emptyRange
        }
        var written = 0
        while written < count {
            let toRead = AVAudioFrameCount(min(Int(chunkCap), count - written))
            buffer.frameLength = 0
            do { try file.read(into: buffer, frameCount: toRead) } catch { break }
            let got = Int(buffer.frameLength)
            if got == 0 { break }
            guard let cd = buffer.floatChannelData else { break }
            for ch in 0..<channelCount {
                let p = cd[ch]
                for i in 0..<got { channels[ch][written + i] = p[i] }
            }
            written += got
        }
        if written < count {
            // Short read (EOF): trim the buffers so trailing zeros don't skew RMS.
            for ch in 0..<channelCount { channels[ch].removeLast(count - written) }
        }
        let n = written
        guard n > 0 else { throw AudioStatsError.emptyRange }

        // Sample peak + pooled RMS over every channel.
        var peak: Double = 0
        var sumSquares: Double = 0
        for ch in channels {
            for v in ch {
                let a = abs(Double(v))
                if a > peak { peak = a }
                sumSquares += Double(v) * Double(v)
            }
        }
        let meanSquare = sumSquares / Double(n * channelCount)
        let rmsDBFS = meanSquare > 0 ? 10 * log10(meanSquare) : .nan
        let peakDBFS = peak > 0 ? 20 * log10(peak) : .nan

        let truePeak = truePeakLinear(channels: channels)
        let truePeakDBTP = truePeak > 0 ? 20 * log10(truePeak) : .nan

        let lufs = integratedLoudness(channels: channels, sampleRate: sampleRate)

        return AmplitudeStats(rmsDBFS: rmsDBFS,
                              peakDBFS: peakDBFS,
                              truePeakDBTP: truePeakDBTP,
                              lufs: lufs,
                              channelCount: channelCount,
                              frameCount: n)
    }

    // MARK: - True peak (inter-sample peak via 4× polyphase oversampling)

    /// Largest inter-sample magnitude across channels, found by reconstructing the
    /// signal 4× with a windowed-sinc polyphase FIR. Returns a linear amplitude.
    private static func truePeakLinear(channels: [[Float]]) -> Double {
        let os = 4
        let tapsPerPhase = 12
        let length = os * tapsPerPhase
        let center = Double(length - 1) / 2

        // Windowed-sinc low-pass prototype (cutoff = π/os), Hann-windowed.
        var proto = [Double](repeating: 0, count: length)
        for i in 0..<length {
            let t = Double(i) - center
            let arg = Double.pi * t / Double(os)
            let sinc = abs(t) < 1e-9 ? 1.0 : sin(arg) / arg
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(length - 1))
            proto[i] = sinc * w
        }
        // Split into `os` phase sub-filters, each normalized to unity DC gain.
        var phases = [[Double]](repeating: [], count: os)
        for p in 0..<os {
            var sub = [Double]()
            var idx = p
            while idx < length { sub.append(proto[idx]); idx += os }
            let sum = sub.reduce(0, +)
            if abs(sum) > 1e-12 { for k in 0..<sub.count { sub[k] /= sum } }
            phases[p] = sub
        }

        var maxAbs: Double = 0
        for ch in channels {
            let nCh = ch.count
            // Raw samples are themselves valid reconstruction points (phase 0).
            for v in ch { let a = abs(Double(v)); if a > maxAbs { maxAbs = a } }
            for p in 1..<os {
                let h = phases[p]
                let m = h.count
                for i in 0..<nCh {
                    var acc = 0.0
                    for k in 0..<m {
                        let xi = i - k
                        if xi >= 0 { acc += h[k] * Double(ch[xi]) }
                    }
                    let a = abs(acc)
                    if a > maxAbs { maxAbs = a }
                }
            }
        }
        return maxAbs
    }

    // MARK: - Integrated loudness (ITU-R BS.1770-4)

    /// Integrated loudness in LUFS for the selection. Applies the K-weighting
    /// filter per channel, then 400 ms blocks (75 % overlap) with the absolute
    /// (−70 LUFS) and relative (−10 LU) gates. Channel weights are 1.0 (correct
    /// for mono/stereo; surround channels are not up-weighted). Falls back to an
    /// ungated whole-selection loudness when the slice is shorter than one block.
    private static func integratedLoudness(channels: [[Float]], sampleRate: Double) -> Double {
        guard let first = channels.first, !first.isEmpty else { return .nan }
        let n = first.count

        let s1 = highShelfStage1(sampleRate: sampleRate)
        let s2 = highPassStage2(sampleRate: sampleRate)
        let filtered = channels.map { biquad(biquad($0, s1), s2) }

        func channelSumMeanSquare(start: Int, length: Int) -> Double {
            var z = 0.0
            for ch in filtered {
                var s = 0.0
                let end = min(ch.count, start + length)
                if end <= start { continue }
                for i in start..<end { s += Double(ch[i]) * Double(ch[i]) }
                z += s / Double(end - start)
            }
            return z
        }

        let blockLen = Int(0.4 * sampleRate)
        let step = max(1, Int(0.1 * sampleRate))

        // Selection shorter than one block: single ungated loudness value.
        guard blockLen > 0, n >= blockLen else {
            let z = channelSumMeanSquare(start: 0, length: n)
            return z > 0 ? -0.691 + 10 * log10(z) : .nan
        }

        var blocks: [(loudness: Double, z: Double)] = []
        var start = 0
        while start + blockLen <= n {
            let z = channelSumMeanSquare(start: start, length: blockLen)
            if z > 0 { blocks.append((-0.691 + 10 * log10(z), z)) }
            start += step
        }
        guard !blocks.isEmpty else { return .nan }

        // Absolute gate at −70 LUFS.
        let absGated = blocks.filter { $0.loudness >= -70 }
        guard !absGated.isEmpty else { return .nan }

        // Relative gate: 10 LU below the mean loudness of the absolute-gated set.
        let meanZ = absGated.reduce(0.0) { $0 + $1.z } / Double(absGated.count)
        let relThreshold = -0.691 + 10 * log10(meanZ) - 10
        let gated = absGated.filter { $0.loudness >= relThreshold }
        let set = gated.isEmpty ? absGated : gated

        let finalMeanZ = set.reduce(0.0) { $0 + $1.z } / Double(set.count)
        return finalMeanZ > 0 ? -0.691 + 10 * log10(finalMeanZ) : .nan
    }

    /// BS.1770 stage 1: high-frequency shelving "head" filter (~+4 dB).
    private static func highShelfStage1(sampleRate fs: Double) -> Biquad {
        let f0 = 1681.974450955533
        let gain = 3.999843853973347
        let q = 0.7071752369554196
        let k = tan(Double.pi * f0 / fs)
        let vh = pow(10.0, gain / 20.0)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1.0 + k / q + k * k
        return Biquad(b0: (vh + vb * k / q + k * k) / a0,
                      b1: 2.0 * (k * k - vh) / a0,
                      b2: (vh - vb * k / q + k * k) / a0,
                      a1: 2.0 * (k * k - 1.0) / a0,
                      a2: (1.0 - k / q + k * k) / a0)
    }

    /// BS.1770 stage 2: ~38 Hz high-pass.
    private static func highPassStage2(sampleRate fs: Double) -> Biquad {
        let f0 = 38.13547087602444
        let q = 0.5003270373238773
        let k = tan(Double.pi * f0 / fs)
        let a0 = 1.0 + k / q + k * k
        return Biquad(b0: 1.0, b1: -2.0, b2: 1.0,
                      a1: 2.0 * (k * k - 1.0) / a0,
                      a2: (1.0 - k / q + k * k) / a0)
    }

    private struct Biquad { let b0, b1, b2, a1, a2: Double }

    /// Direct Form I biquad (a0 normalized to 1), applied over one channel.
    private static func biquad(_ x: [Float], _ c: Biquad) -> [Float] {
        var y = [Float](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<x.count {
            let xn = Double(x[i])
            let yn = c.b0 * xn + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
            y[i] = Float(yn)
            x2 = x1; x1 = xn
            y2 = y1; y1 = yn
        }
        return y
    }
}
