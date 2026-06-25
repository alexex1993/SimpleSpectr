//
//  RenderPreferences.swift
//  SimpleSpectr
//
//  Stores the user's spectrogram analysis + presentation settings (FFT size,
//  STFT overlap, window function, frequency scale) in UserDefaults.
//

import Foundation
import Combine

/// Tracks spectrogram render settings, persisted across launches.
/// - `fftSize` / `overlapPercent` / `windowFunction` change the analysis → the
///   audio is re-decoded.
/// - `frequencyScale` only re-presents the cached spectrogram → instant.
@MainActor
final class RenderPreferences: ObservableObject {
    static let shared = RenderPreferences()

    private enum Keys {
        static let fftSize = "spectrogramFFTSize"
        static let overlapPercent = "spectrogramOverlap"
        static let windowFunction = "spectrogramWindow"
        static let frequencyScale = "spectrogramFrequencyScale"
        static let showWaveform = "spectrogramShowWaveform"
        static let showHarmonics = "spectrogramShowHarmonics"
    }

    /// Selectable FFT window sizes (powers of two).
    static let fftSizeOptions = [256, 512, 1024, 2048, 4096, 8192, 16384]

    /// Selectable STFT overlap percentages.
    static let overlapOptions: [Double] = [0, 25, 50, 75, 87.5]

    static let defaultFFTSize = 2048
    static let defaultOverlap: Double = 75
    static let defaultWindow: WindowFunction = .hann
    static let defaultScale: FrequencyScale = .linear

    @Published var fftSize: Int {
        didSet { UserDefaults.standard.set(fftSize, forKey: Keys.fftSize) }
    }
    @Published var overlapPercent: Double {
        didSet { UserDefaults.standard.set(overlapPercent, forKey: Keys.overlapPercent) }
    }
    @Published var windowFunction: WindowFunction {
        didSet { UserDefaults.standard.set(windowFunction.rawValue, forKey: Keys.windowFunction) }
    }
    @Published var frequencyScale: FrequencyScale {
        didSet { UserDefaults.standard.set(frequencyScale.rawValue, forKey: Keys.frequencyScale) }
    }

    // Display-only overlay toggles. These don't re-analyze the file — the
    // waveform and pitch data are always computed at load — so `SpectrogramModel`
    // deliberately does not observe them.
    @Published var showWaveform: Bool {
        didSet { UserDefaults.standard.set(showWaveform, forKey: Keys.showWaveform) }
    }
    @Published var showHarmonics: Bool {
        didSet { UserDefaults.standard.set(showHarmonics, forKey: Keys.showHarmonics) }
    }

    private init() {
        let savedFFT = UserDefaults.standard.object(forKey: Keys.fftSize) as? Int
        fftSize = Self.fftSizeOptions.contains(savedFFT ?? 0) ? savedFFT! : Self.defaultFFTSize

        let savedOverlap = UserDefaults.standard.object(forKey: Keys.overlapPercent) as? Double
        overlapPercent = savedOverlap ?? Self.defaultOverlap

        let savedWindowRaw = UserDefaults.standard.string(forKey: Keys.windowFunction)
        windowFunction = WindowFunction(rawValue: savedWindowRaw ?? "") ?? Self.defaultWindow

        let savedScaleRaw = UserDefaults.standard.string(forKey: Keys.frequencyScale)
        frequencyScale = FrequencyScale(rawValue: savedScaleRaw ?? "") ?? Self.defaultScale

        let defaults = UserDefaults.standard
        // Waveform lane on by default; pitch / harmonic overlays off until asked.
        showWaveform = defaults.object(forKey: Keys.showWaveform) as? Bool ?? true
        showHarmonics = defaults.object(forKey: Keys.showHarmonics) as? Bool ?? false
    }
}
