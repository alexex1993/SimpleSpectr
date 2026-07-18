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
        static let magnitudeScale = "spectrogramMagnitudeScale"
        static let channelMode = "spectrogramChannelMode"
        static let showWaveform = "spectrogramShowWaveform"
        static let showHarmonics = "spectrogramShowHarmonics"
        static let followPlayhead = "spectrogramFollowPlayhead"
        static let dbFloor = "spectrogramDBFloor"
        static let dbCeiling = "spectrogramDBCeiling"
        static let referenceLevel = "spectrogramReferenceLevel"
    }

    /// Selectable FFT window sizes (powers of two).
    static let fftSizeOptions = [256, 512, 1024, 2048, 4096, 8192, 16384]

    /// Selectable STFT overlap percentages.
    static let overlapOptions: [Double] = [0, 25, 50, 75, 87.5]

    static let defaultFFTSize = 2048
    static let defaultOverlap: Double = 75
    static let defaultWindow: WindowFunction = .hann
    static let defaultScale: FrequencyScale = .linear
    static let defaultMagnitudeScale: MagnitudeScale = .logarithmic
    static let defaultChannelMode: ChannelMode = .mix

    // Color-mapping window (dBFS). `dbFloor` maps to the darkest color, `dbCeiling`
    // to the brightest; `referenceLevel` is a gain (dB) added to the grid before
    // mapping, so positive values brighten quiet material without touching the
    // window's shape. All three are display-only — `SpectrogramModel` re-renders
    // from the cached dB grid, no audio re-decode.
    static let defaultDBFloor: Double = -90
    static let defaultDBCeiling: Double = 0
    static let defaultReferenceLevel: Double = 0
    static let dbFloorRange: ClosedRange<Double> = -120 ... -20
    static let dbCeilingRange: ClosedRange<Double> = -60 ... 6
    static let referenceLevelRange: ClosedRange<Double> = -40 ... 40

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

    /// Magnitude mapping (dB vs linear amplitude). Display-only — re-colors from
    /// the cached grid, no re-decode.
    @Published var magnitudeScale: MagnitudeScale {
        didSet { UserDefaults.standard.set(magnitudeScale.rawValue, forKey: Keys.magnitudeScale) }
    }

    /// Which channel/derivation of a multi-channel file the STFT analyzes.
    /// Analysis setting — changing it re-decodes the file.
    @Published var channelMode: ChannelMode {
        didSet { UserDefaults.standard.set(channelMode.rawValue, forKey: Keys.channelMode) }
    }

    // Color-mapping window / gain (display-only). Clamped to their ranges.
    @Published var dbFloor: Double {
        didSet { UserDefaults.standard.set(dbFloor, forKey: Keys.dbFloor) }
    }
    @Published var dbCeiling: Double {
        didSet { UserDefaults.standard.set(dbCeiling, forKey: Keys.dbCeiling) }
    }
    @Published var referenceLevel: Double {
        didSet { UserDefaults.standard.set(referenceLevel, forKey: Keys.referenceLevel) }
    }

    /// Effective color-mapping window on the *grid* dB values, folding the
    /// reference-level gain into the floor/ceiling. A positive reference slides
    /// the window down so quieter grid values land higher on the color scale
    /// (i.e. the image brightens). Guaranteed `max > min`.
    var colorWindow: (min: Float, max: Float) {
        let lo = dbFloor - referenceLevel
        let hi = dbCeiling - referenceLevel
        return (Float(lo), Float(max(lo + 1, hi)))
    }

    /// Restore the color window and reference level to their factory values.
    func resetLevels() {
        dbFloor = Self.defaultDBFloor
        dbCeiling = Self.defaultDBCeiling
        referenceLevel = Self.defaultReferenceLevel
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

    /// When on, the plot auto-scrolls during playback to keep the playhead in
    /// view: once the playhead reaches the right edge, the spectrogram scrolls so
    /// it stays visible. Display-only — never re-analyzes the file.
    @Published var followPlayhead: Bool {
        didSet { UserDefaults.standard.set(followPlayhead, forKey: Keys.followPlayhead) }
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

        let savedMagRaw = UserDefaults.standard.string(forKey: Keys.magnitudeScale)
        magnitudeScale = MagnitudeScale(rawValue: savedMagRaw ?? "") ?? Self.defaultMagnitudeScale

        let savedChannelRaw = UserDefaults.standard.string(forKey: Keys.channelMode)
        channelMode = ChannelMode(rawValue: savedChannelRaw ?? "") ?? Self.defaultChannelMode

        let defaults = UserDefaults.standard
        // Waveform lane on by default; pitch / harmonic overlays off until asked.
        showWaveform = defaults.object(forKey: Keys.showWaveform) as? Bool ?? true
        showHarmonics = defaults.object(forKey: Keys.showHarmonics) as? Bool ?? false
        // Auto-follow the playhead by default so playback stays visible when zoomed.
        followPlayhead = defaults.object(forKey: Keys.followPlayhead) as? Bool ?? true

        let savedFloor = defaults.object(forKey: Keys.dbFloor) as? Double ?? Self.defaultDBFloor
        dbFloor = savedFloor.clamped(to: Self.dbFloorRange)
        let savedCeiling = defaults.object(forKey: Keys.dbCeiling) as? Double ?? Self.defaultDBCeiling
        dbCeiling = savedCeiling.clamped(to: Self.dbCeilingRange)
        let savedRef = defaults.object(forKey: Keys.referenceLevel) as? Double ?? Self.defaultReferenceLevel
        referenceLevel = savedRef.clamped(to: Self.referenceLevelRange)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
