//
//  LiveSpectrogram.swift
//  SimpleSpectr
//
//  Streaming STFT accumulator that feeds a live spectrogram preview while
//  recording from the microphone. Samples are pushed from the audio thread
//  (`append`) and a preview image is pulled from the main thread (`snapshotImage`),
//  so all shared state is guarded by an `NSLock`.
//
//  The per-column FFT math here is a deliberate mirror of the batch path in
//  `SpectrogramEngine.generate` (same window normalization: `2/winSum`, DC ×0.5,
//  drop Nyquist, `vDSP_vdbcon`). Keep the two in sync.
//
//  Smoothness: rather than keeping every STFT column and re-rendering the whole
//  history each frame (cost grows with take length), columns are folded into a
//  fixed-width downsampled preview grid as they arrive (peak-hold). When the grid
//  fills up its time resolution is halved and folding continues, so both the
//  per-column update and the per-frame render stay O(width × bins) regardless of
//  how long the recording runs.
//

import Foundation
import Accelerate
import CoreGraphics

/// Incremental STFT for the live recording preview. Thread-safe via an internal
/// lock: the audio thread calls `append`, the main thread calls `snapshotImage`.
final class LiveSpectrogram: @unchecked Sendable {

    private let lock = NSLock()

    // Analysis parameters (fixed for the lifetime of one recording).
    private let fftSize: Int
    private let hop: Int
    private let bins: Int
    private let sampleRate: Double
    private let log2n: vDSP_Length
    private var setup: FFTSetup?           // var so it can be nil'd after destroy
    private let window: [Float]
    private let twoOverWinSum: Float

    // Fixed-width downsampled preview grid (column-major dB): preview[col*bins+bin].
    private let maxWidth: Int
    private var preview: [Float]
    private var previewCols = 0            // completed preview columns
    private var binFactor = 1              // source columns folded per preview column
    private var pendingInBucket = 0        // source columns folded into preview[previewCols]
    private var globalMax: Float = -.greatestFiniteMagnitude

    // Sliding sample buffer; samples before `consumed` have already been framed.
    private var samples: [Float] = []
    private var consumed = 0

    // Reusable FFT scratch (only ever touched under `lock`).
    private var realp: [Float]
    private var imagp: [Float]
    private var windowed: [Float]
    private var mags: [Float]

    /// - Parameters:
    ///   - fftSize: power of two; `bins = fftSize / 2`.
    ///   - overlapPercent: 0…87.5; hop = `fftSize * (1 - overlap/100)`.
    ///   - windowFunction / sampleRate: match the recording input.
    ///   - maxWidth: preview width in columns (≈1600); bounds render cost.
    init(fftSize: Int, overlapPercent: Double, windowFunction: WindowFunction,
         sampleRate: Double, maxWidth: Int) {
        let safeFFT = (fftSize > 0 && fftSize & (fftSize - 1) == 0) ? fftSize : 2048
        self.fftSize = safeFFT
        self.bins = safeFFT / 2
        self.sampleRate = sampleRate
        self.log2n = vDSP_Length(safeFFT.trailingZeroBitCount)
        self.setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        self.maxWidth = max(2, maxWidth)

        let clampedOverlap = min(max(overlapPercent, 0), 87.5)
        self.hop = max(1, Int((Double(safeFFT) * (1.0 - clampedOverlap / 100.0)).rounded()))

        let win = windowFunction.generate(size: safeFFT)
        self.window = win
        var winSum: Float = 0
        vDSP_sve(win, 1, &winSum, vDSP_Length(safeFFT))
        self.twoOverWinSum = winSum > 0 ? 2.0 / winSum : 0

        self.preview = [Float](repeating: -.greatestFiniteMagnitude, count: self.maxWidth * bins)
        self.realp = [Float](repeating: 0, count: bins)
        self.imagp = [Float](repeating: 0, count: bins)
        self.windowed = [Float](repeating: 0, count: safeFFT)
        self.mags = [Float](repeating: 0, count: bins)
    }

    /// Release the FFT setup. Idempotent; call once when the recording stops.
    func finish() {
        lock.lock(); defer { lock.unlock() }
        destroySetup()
    }

    deinit {
        // `finish` is the normal teardown; this guards against a missed call.
        // Safe at deinit (no other references) — no lock needed.
        destroySetup()
    }

    private func destroySetup() {
        if let setup {
            vDSP_destroy_fftsetup(setup)
            self.setup = nil
        }
    }

    /// Push freshly captured mono samples (audio thread). Frames as many new STFT
    /// columns as the buffer now allows.
    func append(_ newSamples: [Float]) {
        guard !newSamples.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard setup != nil else { return }

        samples.append(contentsOf: newSamples)

        while consumed + fftSize <= samples.count {
            computeColumn(at: consumed)
            consumed += hop
        }

        // Drop fully-consumed history; keep the tail of the last frame.
        if consumed > 0 {
            samples.removeFirst(consumed)
            consumed = 0
        }
    }

    /// One STFT column from `samples[start ..< start+fftSize]` folded into the
    /// preview grid (caller holds lock).
    private func computeColumn(at start: Int) {
        guard let setup else { return }

        samples.withUnsafeBufferPointer { sp in
            let src = sp.baseAddress! + start
            vDSP_vmul(src, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
        }

        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(bins))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                ip.baseAddress![0] = 0 // drop Nyquist packed into imagp[0]
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(bins))
            }
        }

        var k = twoOverWinSum
        vDSP_vsmul(mags, 1, &k, &mags, 1, vDSP_Length(bins))
        mags[0] *= 0.5 // DC has no spectral mirror

        var ref: Float = 1.0
        vDSP_vdbcon(mags, 1, &ref, &mags, 1, vDSP_Length(bins), 1)

        for v in mags where v > globalMax { globalMax = v }
        foldIntoPreview()
    }

    /// Peak-hold the just-computed `mags` column into the current preview bucket.
    private func foldIntoPreview() {
        let base = previewCols * bins
        if pendingInBucket == 0 {
            for b in 0..<bins { preview[base + b] = mags[b] }
        } else {
            for b in 0..<bins where mags[b] > preview[base + b] { preview[base + b] = mags[b] }
        }
        pendingInBucket += 1
        if pendingInBucket >= binFactor {
            previewCols += 1
            pendingInBucket = 0
            if previewCols >= maxWidth { compressPreview() }
        }
    }

    /// Halve the preview's time resolution by merging adjacent columns (peak-hold),
    /// freeing the second half for new data. Doubles `binFactor`.
    private func compressPreview() {
        let half = maxWidth / 2
        preview.withUnsafeMutableBufferPointer { p in
            for i in 0..<half {
                let dst = i * bins
                let a = (2 * i) * bins
                let b = (2 * i + 1) * bins
                for k in 0..<bins {
                    let av = p[a + k], bv = p[b + k]
                    p[dst + k] = av > bv ? av : bv
                }
            }
            for i in (half * bins)..<(maxWidth * bins) { p[i] = -.greatestFiniteMagnitude }
        }
        previewCols = half
        binFactor *= 2
    }

    /// Render the current preview to a `CGImage`. Orientation matches
    /// `SpectrogramEngine`: high freq at top, time left→right. Cheap and bounded:
    /// width ≤ `maxWidth`, one output column per preview column.
    func snapshotImage(palette: Palette, scale: FrequencyScale) -> CGImage? {
        lock.lock()
        // Include the in-progress bucket so the leading edge feels live.
        let width = previewCols + (pendingInBucket > 0 ? 1 : 0)
        let snapMax = globalMax
        let grid = width > 0 ? Array(preview[0 ..< width * bins]) : []
        lock.unlock()

        guard width > 0, bins > 0 else { return nil }

        let height = bins
        let dynamicRange: Float = 90
        let maxDB = snapMax.isFinite ? snapMax : 0
        let minDB = maxDB - dynamicRange
        let invRange = 1.0 / max(1e-6, (maxDB - minDB))
        let lut = palette.lut

        let axis = FrequencyAxis.make(scale: scale, sampleRate: sampleRate, fftSize: fftSize, bins: bins)
        let logScale = scale == .logarithmic

        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for col in 0..<width {
                let colBase = col * bins
                for row in 0..<height {
                    let db: Float
                    if logScale, height > 1 {
                        let fracY = Double(height - 1 - row) / Double(height - 1)
                        let freq = axis.frequency(forFraction: fracY)
                        let fbin = freq * Double(fftSize) / sampleRate
                        db = Self.sampleLinear(grid, colBase: colBase, bins: bins, at: fbin)
                    } else {
                        db = grid[colBase + (bins - 1 - row)]
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
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
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
                       intent: .defaultIntent)
    }

    /// Linear interpolation of the dB magnitude at a fractional bin (log resample).
    private static func sampleLinear(_ grid: [Float], colBase: Int, bins: Int, at fractionalBin: Double) -> Float {
        let lo = max(0, min(bins - 1, Int(fractionalBin)))
        let hi = min(bins - 1, lo + 1)
        let frac = Float(max(0, min(1, fractionalBin - Double(lo))))
        let a = grid[colBase + lo]
        let b = grid[colBase + hi]
        return a + (b - a) * frac
    }
}
