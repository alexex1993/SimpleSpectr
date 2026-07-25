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

    /// Channel derivation the grid was analyzed with.
    let channelMode: ChannelMode
    /// Vertical stacking of `image` (one plot, or L above R).
    let paneLayout: PaneLayout
    /// Meaning of `secondary`, when a multi-channel mode produced one.
    let secondaryPlane: SecondaryPlane?
    /// Second data plane, same `[column * bins + bin]` layout as `magnitudes`:
    /// the right channel's dB grid (stacked stereo) or the −1…+1 correlation
    /// grid. `nil` for the single-signal channel modes.
    let secondary: [Float]?

    /// Number of stacked plots in `image`.
    var paneCount: Int { paneLayout.paneCount }

    /// Frequency-axis mapping the image and axes were rendered with. In a
    /// stacked layout this is the axis of *one* pane, not of the whole image.
    var frequencyAxis: FrequencyAxis {
        FrequencyAxis(scale: frequencyScale,
                      sampleRate: sampleRate,
                      fftSize: fftSize,
                      bins: bins,
                      minFrequency: minDisplayedFrequency,
                      maxFrequency: maxFrequency)
    }

    /// The dB grid backing a pane: pane 0 is always `magnitudes`, pane 1 the
    /// right channel. Falls back to the primary grid if a caller asks for a
    /// pane this result doesn't have.
    func grid(forPane pane: Int) -> [Float] {
        (pane == 1 ? secondary : nil) ?? magnitudes
    }

    /// Split a whole-plot vertical fraction (0…1, bottom-origin) into the pane
    /// under it and the fraction *within* that pane. Pane 0 is the top plot.
    func pane(atFractionY fractionY: Double) -> (index: Int, local: Double) {
        let f = min(max(fractionY, 0), 1)
        let n = paneCount
        guard n > 1 else { return (0, f) }
        // Measure downward from the top so pane 0 is the first slice.
        let fromTop = (1 - f) * Double(n)
        let index = min(n - 1, max(0, Int(fromTop)))
        return (index, 1 - (fromTop - Double(index)))
    }

    /// Inverse of `pane(atFractionY:)`: where a frequency sits in the whole plot
    /// when drawn inside `pane`. Used by the overlays (harmonics, selection) so
    /// they land on the pane the user is pointing at.
    func fractionY(forFrequency frequency: Double, pane: Int) -> Double {
        let local = frequencyAxis.fraction(forFrequency: frequency)
        let n = paneCount
        guard n > 1 else { return local }
        let fromTop = (Double(pane) + (1 - min(max(local, 0), 1))) / Double(n)
        return 1 - fromTop
    }

    /// One hovered cell of the plot: the value under the pointer plus the
    /// coordinates it resolved to.
    struct Probe: Equatable, Sendable {
        let time: Double
        let frequency: Double
        let db: Double
        /// Stacked plot the point landed in (0 = top / left channel).
        let pane: Int
        /// Inter-channel correlation at this cell, only in correlation mode.
        let correlation: Double?
    }

    /// Value at a fractional position in the plot (0…1, origin bottom-left),
    /// resolved through the pane under the point.
    func sample(fractionX: Double, fractionY: Double) -> Probe? {
        guard columns > 0, bins > 0 else { return nil }
        let fx = min(max(fractionX, 0), 1)
        let (paneIndex, local) = pane(atFractionY: fractionY)
        let column = min(Int(fx * Double(columns)), columns - 1)
        let axis = frequencyAxis
        let bin = axis.bin(forFraction: local)
        let db = Double(grid(forPane: paneIndex)[column * bins + bin])
        let corr: Double? = secondaryPlane == .correlation
            ? secondary.map { Double($0[column * bins + bin]) }
            : nil
        return Probe(time: fx * duration,
                     frequency: axis.frequency(forFraction: local),
                     db: db,
                     pane: paneIndex,
                     correlation: corr)
    }

    /// Copy keeping the magnitudes but swapping the presented image and frequency
    /// axis (used when re-rendering with a new palette or a new frequency scale).
    func rerendered(image: CGImage,
                    scale: FrequencyScale? = nil,
                    minDisplayedFrequency: Double? = nil,
                    minDB: Double? = nil,
                    maxDB: Double? = nil) -> SpectrogramResult {
        SpectrogramResult(image: image,
                          duration: duration,
                          sampleRate: sampleRate,
                          maxFrequency: maxFrequency,
                          fftSize: fftSize,
                          columns: columns,
                          bins: bins,
                          minDB: minDB ?? self.minDB,
                          maxDB: maxDB ?? self.maxDB,
                          magnitudes: magnitudes,
                          frequencyScale: scale ?? frequencyScale,
                          minDisplayedFrequency: minDisplayedFrequency ?? self.minDisplayedFrequency,
                          waveformMin: waveformMin,
                          waveformMax: waveformMax,
                          channelMode: channelMode,
                          paneLayout: paneLayout,
                          secondaryPlane: secondaryPlane,
                          secondary: secondary)
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
    ///   - minDB / maxDB: color-mapping window in dBFS. The grid dB mapped to the
    ///     darkest / brightest color. Defaults span a 90 dB range up to full scale.
    nonisolated static func generate(url: URL,
                                     fftSize: Int = 2048,
                                     overlapPercent: Double = 75,
                                     windowFunction: WindowFunction = .hann,
                                     frequencyScale: FrequencyScale = .linear,
                                     maxColumns: Int = 2000,
                                     palette: Palette = .inferno,
                                     minDB: Float = -90,
                                     maxDB: Float = 0,
                                     channelMode: ChannelMode = .mix,
                                     magnitudeScale: MagnitudeScale = .logarithmic) throws -> SpectrogramResult {
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

        // Multi-channel modes (stacked stereo / correlation) transform L and R in
        // the same pass, so every per-frame buffer is doubled. The single-signal
        // modes leave the "B" side untouched.
        let dual = channelMode.isDual

        // Scratch buffers for the real FFT (split-complex packing), hoisted out of the loop.
        var realA = [Float](repeating: 0, count: bins)
        var imagA = [Float](repeating: 0, count: bins)
        var realB = [Float](repeating: 0, count: dual ? bins : 0)
        var imagB = [Float](repeating: 0, count: dual ? bins : 0)
        var windowed = [Float](repeating: 0, count: fftSize)
        var magsA = [Float](repeating: 0, count: bins)
        var magsB = [Float](repeating: 0, count: dual ? bins : 0)

        // Column-major magnitude grid in dB: magnitudes[col * bins + bin].
        var magnitudes = [Float](repeating: 0, count: columns * bins)
        // Second plane: the right channel's dB grid, or the correlation grid.
        var secondary = [Float](repeating: 0, count: dual ? columns * bins : 0)
        var globalMax: Float = -.greatestFiniteMagnitude

        // Per-column overview waveform envelope.
        var waveMin = [Float](repeating: 0, count: columns)
        var waveMax = [Float](repeating: 0, count: columns)

        // Decode on the fly through a sequential source so the whole file is
        // never materialized in memory.
        var source = try ChannelSource(file: file, channelCount: channelCount, channelMode: channelMode)
        var samplesA = [Float](repeating: 0, count: fftSize)
        var samplesB = [Float](repeating: 0, count: dual ? fftSize : 0)
        _ = try source.fill(into: &samplesA, and: &samplesB, offset: 0, count: fftSize)

        /// Window one frame and run the forward real FFT into a split-complex pair.
        /// With `fft_zrip`, slot 0 packs DC (real) and Nyquist (imag); Nyquist is
        /// dropped so it does not contaminate the DC magnitude. `mags` receives
        /// the raw (un-normalized) amplitude spectrum.
        func transform(_ samples: [Float],
                       _ realp: inout [Float],
                       _ imagp: inout [Float],
                       _ mags: inout [Float]) {
            vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(bins))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    ip.baseAddress![0] = 0
                    vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(bins))
                }
            }
        }

        /// Amplitude → dBFS in place: factor 2 for the one-sided spectrum divided
        /// by the window's coherent sum, then 20·log₁₀. DC has no spectral mirror,
        /// so it is not doubled.
        func toDecibels(_ mags: inout [Float]) {
            var k = twoOverWinSum
            var ref: Float = 1.0
            let n = vDSP_Length(bins)
            // In-place through one pointer: aliasing the same array as both the
            // source and the destination argument is exactly what vDSP expects,
            // and spelling it this way keeps Swift's exclusivity rules happy.
            mags.withUnsafeMutableBufferPointer { p in
                guard let base = p.baseAddress else { return }
                vDSP_vsmul(base, 1, &k, base, 1, n)
                base[0] *= 0.5
                vDSP_vdbcon(base, 1, &ref, base, 1, n, 1)
            }
        }

        for col in 0..<columns {
            if col > 0 {
                if hop < fftSize {
                    // Overlapping windows: slide the buffer left by `hop`, refill the tail.
                    let keep = fftSize - hop
                    for i in 0..<keep { samplesA[i] = samplesA[i + hop] }
                    if dual { for i in 0..<keep { samplesB[i] = samplesB[i + hop] } }
                    _ = try source.fill(into: &samplesA, and: &samplesB, offset: keep, count: hop)
                } else {
                    // Non-overlapping windows for very long files: skip the gap, read fresh.
                    _ = try source.discard(count: hop - fftSize)
                    _ = try source.fill(into: &samplesA, and: &samplesB, offset: 0, count: fftSize)
                }
            }
            try Task.checkCancellation()

            // Overview waveform: peak min/max of the raw samples in this frame.
            // In a dual mode it spans both channels, so the lane still shows the
            // true envelope of the material.
            var frameMin: Float = 0
            var frameMax: Float = 0
            vDSP_minv(samplesA, 1, &frameMin, vDSP_Length(fftSize))
            vDSP_maxv(samplesA, 1, &frameMax, vDSP_Length(fftSize))
            if dual {
                var bMin: Float = 0
                var bMax: Float = 0
                vDSP_minv(samplesB, 1, &bMin, vDSP_Length(fftSize))
                vDSP_maxv(samplesB, 1, &bMax, vDSP_Length(fftSize))
                frameMin = min(frameMin, bMin)
                frameMax = max(frameMax, bMax)
            }
            waveMin[col] = frameMin
            waveMax[col] = frameMax

            transform(samplesA, &realA, &imagA, &magsA)
            if dual { transform(samplesB, &realB, &imagB, &magsB) }

            let colBase = col * bins

            if channelMode == .correlation {
                // Cross-spectrum, computed on the *raw* FFT output: the shared
                // normalization cancels in the ratio.
                //   cos Δφ = Re(L · conj(R)) / (|L| · |R|)
                // The level plane keeps the mean channel energy so the readout
                // and the color weighting stay meaningful where a phase-inverted
                // pair would cancel in a plain mix.
                for b in 0..<bins {
                    let ma = magsA[b], mb = magsB[b]
                    let den = ma * mb
                    let c = den > 1e-20
                        ? (realA[b] * realB[b] + imagA[b] * imagB[b]) / den
                        : 0
                    secondary[colBase + b] = min(max(c, -1), 1)
                    magsA[b] = (0.5 * (ma * ma + mb * mb)).squareRoot()
                }
            }

            toDecibels(&magsA)
            for b in 0..<bins {
                let v = magsA[b]
                magnitudes[colBase + b] = v
                if v > globalMax { globalMax = v }
            }

            if channelMode == .stereo {
                toDecibels(&magsB)
                for b in 0..<bins {
                    let v = magsB[b]
                    secondary[colBase + b] = v
                    if v > globalMax { globalMax = v }
                }
            }
        }

        // 3. Map dB → color using the caller's window (guard against inversion).
        _ = globalMax // peak is no longer used for the range; kept for potential tooling
        let lo = min(minDB, maxDB)
        let hi = max(lo + 1, max(minDB, maxDB))
        let axis = FrequencyAxis.make(scale: frequencyScale,
                                      sampleRate: sampleRate,
                                      fftSize: fftSize,
                                      bins: bins)
        let secondGrid: [Float]? = dual ? secondary : nil
        let image = try renderImage(magnitudes: magnitudes,
                                    columns: columns,
                                    bins: bins,
                                    minDB: lo,
                                    maxDB: hi,
                                    palette: palette,
                                    frequencyAxis: axis,
                                    magnitudeScale: magnitudeScale,
                                    secondary: secondGrid,
                                    secondaryPlane: channelMode.secondaryPlane,
                                    paneLayout: channelMode.paneLayout)

        return SpectrogramResult(image: image,
                                 duration: Double(total) / sampleRate,
                                 sampleRate: sampleRate,
                                 maxFrequency: sampleRate / 2,
                                 fftSize: fftSize,
                                 columns: columns,
                                 bins: bins,
                                 minDB: Double(lo),
                                 maxDB: Double(hi),
                                 magnitudes: magnitudes,
                                 frequencyScale: frequencyScale,
                                 minDisplayedFrequency: axis.minFrequency,
                                 waveformMin: waveMin,
                                 waveformMax: waveMax,
                                 channelMode: channelMode,
                                 paneLayout: channelMode.paneLayout,
                                 secondaryPlane: channelMode.secondaryPlane,
                                 secondary: secondGrid)
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
    ///
    /// `paneLayout` stacks several plots into one image: `.stackedStereo` gives
    /// `paneCount * bins` rows, pane 0 (from `magnitudes`) on top and pane 1
    /// (from `secondary`) below, split exactly in half so the on-screen fraction
    /// math is a plain even subdivision. When `secondaryPlane` is `.correlation`
    /// the single pane is colored by the signed correlation grid instead of the
    /// palette, with `magnitudes` acting as the energy weight.
    nonisolated static func renderImage(magnitudes: [Float],
                                        columns: Int,
                                        bins: Int,
                                        minDB: Float,
                                        maxDB: Float,
                                        palette: Palette = .inferno,
                                        frequencyAxis: FrequencyAxis? = nil,
                                        magnitudeScale: MagnitudeScale = .logarithmic,
                                        secondary: [Float]? = nil,
                                        secondaryPlane: SecondaryPlane? = nil,
                                        paneLayout: PaneLayout = .single) throws -> CGImage {
        let paneCount = paneLayout.paneCount
        let width = columns
        let height = bins * paneCount
        let invRange = 1.0 / max(1e-6, (maxDB - minDB))
        let lut = palette.lut
        // Any non-linear axis (log/mel/bark/erb) warps each output row onto a
        // fractional bin; the linear axis keeps the fast 1:1 mapping.
        let warpScale = frequencyAxis?.scale.isWarped ?? false
        // For linear-magnitude mapping, precompute the amplitude window that the
        // dB floor/ceiling correspond to (10^(dB/20)) and map amplitude linearly.
        let linearMagnitude = magnitudeScale == .linear
        let ampMin = powf(10, minDB / 20)
        let ampMax = powf(10, maxDB / 20)
        let invAmpRange = 1.0 / max(1e-12, (ampMax - ampMin))
        // Correlation colors the plot by the signed grid; anything else (a
        // stacked right channel, or no second plane at all) is a plain dB pane.
        let correlationGrid = secondaryPlane == .correlation ? secondary : nil
        let panes: [[Float]] = paneCount > 1
            ? [magnitudes, secondary ?? magnitudes]
            : [magnitudes]

        /// Where a row inside a pane samples the grid: an exact bin on the linear
        /// axis, a fractional one on any warped axis.
        func value(_ grid: [Float], colBase: Int, rowInPane: Int) -> Float {
            if warpScale, let axis = frequencyAxis, bins > 1 {
                let fracY = Double(bins - 1 - rowInPane) / Double(bins - 1)
                let freq = axis.frequency(forFraction: fracY)
                let fbin = freq * Double(axis.fftSize) / axis.sampleRate
                return Self.sampleLinear(grid, colBase: colBase, bins: bins, at: fbin)
            }
            // Linear 1:1 — the first row of a pane (its top) is the highest bin.
            return grid[colBase + bins - 1 - rowInPane]
        }

        // Bound once outside the pixel loops: re-binding the optional per pixel
        // would retain/release the grid on every sample.
        let corrGrid = correlationGrid ?? []
        let colorByCorrelation = correlationGrid != nil

        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for pane in 0..<paneCount {
                let grid = panes[pane]
                let rowBase = pane * bins
                for col in 0..<columns {
                    let colBase = col * bins
                    for rowInPane in 0..<bins {
                        let db = value(grid, colBase: colBase, rowInPane: rowInPane)
                        // Map to 0…1 either through the dB window (log) or the
                        // equivalent amplitude window (linear magnitude).
                        var t: Float
                        if linearMagnitude {
                            t = (powf(10, db / 20) - ampMin) * invAmpRange
                        } else {
                            t = (db - minDB) * invRange
                        }
                        if !t.isFinite { t = 0 }
                        if t < 0 { t = 0 } else if t > 1 { t = 1 }
                        let rgb: (UInt8, UInt8, UInt8)
                        if colorByCorrelation {
                            // `t` is the level, which fades quiet bins toward the
                            // background so a noise floor's phase stays invisible.
                            rgb = CorrelationColormap.color(
                                correlation: value(corrGrid, colBase: colBase, rowInPane: rowInPane),
                                weight: t)
                        } else {
                            rgb = lut[Int(t * 255)]
                        }
                        let offset = ((rowBase + rowInPane) * width + col) * 4
                        p[offset + 0] = rgb.0
                        p[offset + 1] = rgb.1
                        p[offset + 2] = rgb.2
                        p[offset + 3] = 255
                    }
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

// MARK: - Sequential decoder

/// Reads an `AVAudioFile` forward and hands out the derived analysis signal(s) on
/// demand. Only a small chunk is ever held in memory, so long files don't blow up
/// the heap.
///
/// Single-signal modes (mix / left / right / mid / side) produce one stream in
/// `pendingA`. The dual modes (`stereo`, `correlation`) additionally fill
/// `pendingB`, so a stereo file's two channels stay aligned sample-for-sample
/// through one forward pass — a second pass would have to re-decode the file.
nonisolated private struct ChannelSource {
    private let file: AVAudioFile
    private let channelCount: Int
    private let channelMode: ChannelMode
    private let isDual: Bool
    private let chunkFrames: AVAudioFrameCount
    private let buffer: AVAudioPCMBuffer

    private var pendingA: [Float] = []
    private var pendingB: [Float] = []
    private var pendingOffset = 0
    private var eof = false

    init(file: AVAudioFile, channelCount: Int, channelMode: ChannelMode = .mix) throws {
        self.file = file
        self.channelCount = channelCount
        self.channelMode = channelMode
        self.isDual = channelMode.isDual
        self.chunkFrames = 1 << 18 // 262144 frames per read
        // Allocation can fail (invalid format / out of memory); fail loudly with a
        // recoverable error rather than trapping mid-decode.
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 18) else {
            throw SpectrogramError.cannotOpen("Could not allocate decode buffer")
        }
        self.buffer = buffer
    }

    /// Copy up to `count` samples into `a[offset..<]` (and, in a dual mode, the
    /// matching right-channel samples into `b`). Returns the number copied.
    /// `b` is ignored — and may be empty — outside the dual modes.
    mutating func fill(into a: inout [Float], and b: inout [Float],
                       offset: Int, count: Int) throws -> Int {
        var written = 0
        while written < count {
            if pendingOffset >= pendingA.count {
                if eof { break }
                try decodeNextChunk()
                if pendingOffset >= pendingA.count { break }
            }
            let take = min(count - written, pendingA.count - pendingOffset)
            for i in 0..<take {
                a[offset + written + i] = pendingA[pendingOffset + i]
            }
            if isDual {
                for i in 0..<take {
                    b[offset + written + i] = pendingB[pendingOffset + i]
                }
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
            if pendingOffset >= pendingA.count {
                if eof { break }
                try decodeNextChunk()
                if pendingOffset >= pendingA.count { break }
            }
            let take = min(count - discarded, pendingA.count - pendingOffset)
            pendingOffset += take
            discarded += take
        }
        return discarded
    }

    /// Read one chunk from the file into `pendingA` (+ `pendingB` when dual).
    /// Safe at EOF: returns without throwing, leaving the buffers empty.
    /// `read(into:)` throws at EOF, so the loop is driven by
    /// `framePosition < length` and reads `min(chunk, remaining)`.
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

        pendingA.removeAll(keepingCapacity: true)
        pendingB.removeAll(keepingCapacity: true)
        pendingOffset = 0

        // Mono files (or a source with a single channel) collapse every mode to
        // the one available channel — including the dual modes, where both sides
        // then carry the same signal (correlation reads a constant +1).
        if channelCount == 1 {
            let p = channels[0]
            pendingA.append(contentsOf: UnsafeBufferPointer(start: p, count: frames))
            if isDual { pendingB = pendingA }
            return
        }

        let left = channels[0]
        let right = channels[1]   // channelCount >= 2 here

        if isDual {
            pendingA.append(contentsOf: UnsafeBufferPointer(start: left, count: frames))
            pendingB.append(contentsOf: UnsafeBufferPointer(start: right, count: frames))
            return
        }

        pendingA = [Float](repeating: 0, count: frames)

        switch channelMode {
        case .left:
            pendingA.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: left, count: frames)
            }
        case .right:
            pendingA.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: right, count: frames)
            }
        case .mid:
            // Mid = (L + R) / 2.
            vDSP_vadd(left, 1, right, 1, &pendingA, 1, vDSP_Length(frames))
            var half: Float = 0.5
            vDSP_vsmul(pendingA, 1, &half, &pendingA, 1, vDSP_Length(frames))
        case .side:
            // Side = (L - R) / 2.
            vDSP_vsub(right, 1, left, 1, &pendingA, 1, vDSP_Length(frames)) // L - R
            var half: Float = 0.5
            vDSP_vsmul(pendingA, 1, &half, &pendingA, 1, vDSP_Length(frames))
        case .mix:
            // Average of every channel (down-mix to mono).
            for ch in 0..<channelCount {
                vDSP_vadd(pendingA, 1, channels[ch], 1, &pendingA, 1, vDSP_Length(frames))
            }
            var inv = 1.0 / Float(channelCount)
            vDSP_vsmul(pendingA, 1, &inv, &pendingA, 1, vDSP_Length(frames))
        case .stereo, .correlation:
            break // handled above by the dual path
        }
    }
}
