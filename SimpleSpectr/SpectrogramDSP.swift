//
//  SpectrogramDSP.swift
//  SimpleSpectr
//
//  Shared DSP types used by the engine and the UI: window functions, frequency
//  scale mapping, and musical-note helpers for the log-frequency axis overlay.
//

import Foundation

/// Selectable STFT window function. Each case generates its own periodic
/// (DFT-even) window of a given size; the engine normalizes by the window's
/// coherent sum, so amplitude stays calibrated regardless of the choice.
nonisolated enum WindowFunction: String, CaseIterable, Identifiable, Sendable {
    case hann
    case blackmanHarris
    case kaiser
    case flattop

    var id: String { rawValue }

    /// Whether this is the factory default (shown with a "Default" caption).
    var isDefault: Bool { self == .hann }

    /// Display name — window names are proper nouns, kept verbatim.
    var displayName: String {
        switch self {
        case .hann:           return "Hann"
        case .blackmanHarris: return "Blackman-Harris"
        case .kaiser:         return "Kaiser"
        case .flattop:        return "Flattop"
        }
    }

    /// A short, user-facing description of the trade-off each window makes.
    @MainActor var hint: String {
        switch self {
        case .hann:           return L("window.hann.hint")
        case .blackmanHarris: return L("window.blackmanHarris.hint")
        case .kaiser:         return L("window.kaiser.hint")
        case .flattop:        return L("window.flattop.hint")
        }
    }

    /// Build the window samples (periodic form, n = 0..<size, argument 2πn/size).
    func generate(size: Int) -> [Float] {
        guard size > 0 else { return [] }
        let n = Double(size)
        switch self {
        case .hann:
            return (0..<size).map { i in
                Float(0.5 - 0.5 * cos(2.0 * .pi * Double(i) / n))
            }
        case .blackmanHarris:
            // 4-term minimum-resolution Blackman-Harris.
            let a0 = 0.35875, a1 = 0.48829, a2 = 0.14128, a3 = 0.01168
            return (0..<size).map { i in
                let t = 2.0 * .pi * Double(i) / n
                return Float(a0 - a1 * cos(t) + a2 * cos(2 * t) - a3 * cos(3 * t))
            }
        case .kaiser:
            // β ≈ 8.6 → ~60 dB sidelobe attenuation, good main-lobe width.
            let beta = 8.6
            let denom = (n - 1) / 2.0
            let denomI0 = Self.besselI0(beta)
            return (0..<size).map { i in
                let r = (Double(i) - denom) / denom
                let arg = beta * sqrt(max(0, 1 - r * r))
                return Float(Self.besselI0(arg) / denomI0)
            }
        case .flattop:
            // Standard 5-term flattop — best amplitude accuracy, widest lobe.
            let a0 = 0.21557895, a1 = 0.41663158, a2 = 0.277263158
            let a3 = 0.083578947, a4 = 0.006947368
            return (0..<size).map { i in
                let t = 2.0 * .pi * Double(i) / n
                return Float(a0 - a1 * cos(t) + a2 * cos(2 * t)
                             - a3 * cos(3 * t) + a4 * cos(4 * t))
            }
        }
    }

    /// Modified Bessel function of the first kind, order 0 (series expansion).
    /// Used by the Kaiser window.
    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        let x2 = (x / 2.0) * (x / 2.0)
        var k = 1
        while k < 100 {
            term *= x2 / Double(k * k)
            sum += term
            if abs(term) < 1e-12 * sum { break }
            k += 1
        }
        return sum
    }
}

/// Frequency-axis presentation mode for the spectrogram. `linear` and
/// `logarithmic` are the classic axes; `mel`, `bark` and `erb` are perceptual
/// scales that compress the highs the way human hearing does (Mel = 2595·log₁₀,
/// Bark = critical-band rate, ERB = equivalent-rectangular-bandwidth rate).
nonisolated enum FrequencyScale: String, CaseIterable, Identifiable, Sendable {
    case linear
    case logarithmic
    case mel
    case bark
    case erb

    var id: String { rawValue }

    @MainActor var displayName: String {
        switch self {
        case .linear:       return L("scale.linear")
        case .logarithmic:  return L("scale.logarithmic")
        case .mel:          return L("scale.mel")
        case .bark:         return L("scale.bark")
        case .erb:          return L("scale.erb")
        }
    }

    var isDefault: Bool { self == .linear }

    /// `true` for any scale whose image rows are not a 1:1 map onto the linear
    /// FFT bins (i.e. everything except `.linear`), so the renderer resamples.
    var isWarped: Bool { self != .linear }

    /// `true` only for the logarithmic scale, which draws musical-note labels and
    /// octave gridlines instead of plain Hz ticks.
    var usesNoteLabels: Bool { self == .logarithmic }
}

/// Magnitude-mapping mode: how the STFT amplitude drives the colormap.
/// `logarithmic` maps decibels (the calibrated dBFS grid, default); `linear`
/// maps raw amplitude, which crushes quiet detail but shows relative energy.
/// Display-only — the cached dB grid is untouched, so a change re-colors from
/// cache without re-decoding audio.
nonisolated enum MagnitudeScale: String, CaseIterable, Identifiable, Sendable {
    case logarithmic
    case linear

    var id: String { rawValue }

    @MainActor var displayName: String {
        switch self {
        case .logarithmic: return L("magnitude.logarithmic")
        case .linear:      return L("magnitude.linear")
        }
    }

    var isDefault: Bool { self == .logarithmic }
}

/// Which signal the mono STFT source analyzes from a multi-channel file.
/// `mix` averages every channel (the classic behavior); `left`/`right` pick a
/// single channel; `mid`/`side` form the M/S sum and difference. An analysis
/// setting — changing it re-decodes the file. On mono files every mode collapses
/// to the single available channel.
nonisolated enum ChannelMode: String, CaseIterable, Identifiable, Sendable {
    case mix
    case left
    case right
    case mid
    case side

    var id: String { rawValue }

    @MainActor var displayName: String {
        switch self {
        case .mix:   return L("channel.mix")
        case .left:  return L("channel.left")
        case .right: return L("channel.right")
        case .mid:   return L("channel.mid")
        case .side:  return L("channel.side")
        }
    }

    var isDefault: Bool { self == .mix }
}

/// Maps a 0…1 vertical fraction (bottom…top of the plot) to/from a physical
/// frequency and an FFT bin, for either a linear or a logarithmic axis. Shared
/// by the renderer (so the image and axis stay aligned) and by the hover sample.
nonisolated struct FrequencyAxis: Sendable {
    let scale: FrequencyScale
    let sampleRate: Double
    let fftSize: Int
    let bins: Int
    let minFrequency: Double     // bottom of the plot (Hz); 0 for linear
    let maxFrequency: Double     // top of the plot (Hz) — Nyquist

    /// Build the axis for a spectrogram of the given dimensions.
    static func make(scale: FrequencyScale,
                     sampleRate: Double,
                     fftSize: Int,
                     bins: Int) -> FrequencyAxis {
        let maxF = sampleRate / 2
        let minF: Double
        switch scale {
        case .logarithmic: minF = min(Self.logMin, maxF / 2) // ensure ≥ 1 octave
        // Linear and the perceptual scales (mel/bark/erb) are all well-defined at
        // 0 Hz, so they anchor the bottom of the plot at DC.
        case .linear, .mel, .bark, .erb: minF = 0
        }
        return FrequencyAxis(scale: scale,
                             sampleRate: sampleRate,
                             fftSize: fftSize,
                             bins: bins,
                             minFrequency: minF,
                             maxFrequency: maxF)
    }

    /// Bottom anchor for the log axis: A0 (27.5 Hz) — the piano's lowest key.
    static let logMin: Double = 27.5

    /// Fraction (0…1, bottom…top) → frequency (Hz). Every scale is expressed as a
    /// monotonic `warp`/`unwarp` pair, and the fraction interpolates linearly
    /// between the warped end-points, so the image rows and axis labels agree.
    func frequency(forFraction f: Double) -> Double {
        let f = min(max(f, 0), 1)
        let wLo = Self.warp(minFrequency, scale: scale)
        let wHi = Self.warp(maxFrequency, scale: scale)
        return Self.unwarp(wLo + f * (wHi - wLo), scale: scale)
    }

    /// Frequency (Hz) → fraction (0…1, bottom…top). May fall outside [0,1].
    func fraction(forFrequency freq: Double) -> Double {
        let wLo = Self.warp(minFrequency, scale: scale)
        let wHi = Self.warp(maxFrequency, scale: scale)
        guard wHi > wLo else { return 0 }
        return (Self.warp(freq, scale: scale) - wLo) / (wHi - wLo)
    }

    // MARK: - Scale warps

    /// Hz → warped axis units (monotonic increasing). The fraction↔frequency
    /// mapping normalizes by the warped end-points, so only the *shape* matters.
    private static func warp(_ f: Double, scale: FrequencyScale) -> Double {
        switch scale {
        case .linear:      return f
        case .logarithmic: return f > 0 ? log(f) : log(1e-6)
        case .mel:         return 2595.0 * log10(1.0 + f / 700.0)
        case .bark:        return 26.81 * f / (1960.0 + f) - 0.53   // Traunmüller
        case .erb:         return 21.4 * log10(1.0 + 0.00437 * f)   // Glasberg-Moore
        }
    }

    /// Inverse of `warp` — warped axis units → Hz.
    private static func unwarp(_ w: Double, scale: FrequencyScale) -> Double {
        switch scale {
        case .linear:      return w
        case .logarithmic: return exp(w)
        case .mel:         return 700.0 * (pow(10.0, w / 2595.0) - 1.0)
        case .bark:        return 1960.0 * (w + 0.53) / (26.28 - w)
        case .erb:         return (pow(10.0, w / 21.4) - 1.0) / 0.00437
        }
    }

    /// Fraction (0…1, bottom…top) → nearest FFT bin index, clamped to the grid.
    func bin(forFraction f: Double) -> Int {
        let freq = frequency(forFraction: f)
        var b = Int(round(freq * Double(fftSize) / sampleRate))
        if b < 0 { b = 0 }
        if b >= bins { b = bins - 1 }
        return b
    }
}

/// Musical-note helpers for the log-frequency axis overlay (A4 = 440 Hz).
nonisolated enum MusicNotes {
    static let a4Frequency: Double = 440.0
    static let a4MIDI: Int = 69
    private static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    /// MIDI note number → frequency (Hz), equal temperament.
    static func frequency(midi: Int) -> Double {
        a4Frequency * pow(2.0, Double(midi - a4MIDI) / 12.0)
    }

    /// MIDI note number → name with octave, e.g. 60 → "C4", 69 → "A4".
    static func name(midi: Int) -> String {
        let octave = (midi / 12) - 1
        return "\(names[midi % 12])\(octave)"
    }
}
