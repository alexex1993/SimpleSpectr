//
//  Measurement.swift
//  SimpleSpectr
//
//  Region-measurement support: a time × frequency selection on the spectrogram,
//  the peak-frequency scan over that region (from the cached dB grid), and an
//  observable owner that runs the amplitude-statistics analyzer off the main
//  actor. The view layer (SpectrogramScene) drives the selection and presents
//  the results; the delta/peak math is cheap and synchronous, the amplitude
//  stats (RMS / true-peak / LUFS) are async because they re-read the file.
//

import Foundation
import SwiftUI
import Combine

/// A drag selection over the plot. `anchor` is where the drag began, `focus`
/// where it currently/last ended, so the signed deltas keep their direction;
/// the time/frequency ranges are the sorted span for region scans.
struct PlotSelection: Equatable {
    var anchorTime: Double
    var anchorFreq: Double
    var focusTime: Double
    var focusFreq: Double

    var timeRange: ClosedRange<Double> {
        min(anchorTime, focusTime)...max(anchorTime, focusTime)
    }
    var freqRange: ClosedRange<Double> {
        min(anchorFreq, focusFreq)...max(anchorFreq, focusFreq)
    }
    var deltaTime: Double { focusTime - anchorTime }
    var deltaFreq: Double { focusFreq - anchorFreq }

    /// Whether the selection spans a usable area (not just a click).
    var isMeaningful: Bool {
        abs(deltaTime) > 1e-4 || abs(deltaFreq) > 1.0
    }
}

extension SpectrogramResult {
    /// Loudest dB cell inside a time × frequency region, scanned from the cached
    /// magnitude grid. Returns its resolved time, frequency and dB.
    func regionPeak(timeRange: ClosedRange<Double>,
                    freqRange: ClosedRange<Double>) -> (time: Double, frequency: Double, db: Double)? {
        guard columns > 0, bins > 0, duration > 0, fftSize > 0 else { return nil }

        func column(_ t: Double) -> Int {
            max(0, min(columns - 1, Int(t / duration * Double(columns))))
        }
        func bin(_ f: Double) -> Int {
            max(0, min(bins - 1, Int((f * Double(fftSize) / sampleRate).rounded())))
        }

        let cLo = column(timeRange.lowerBound)
        let cHi = max(cLo, column(timeRange.upperBound))
        let bLo = bin(max(0, freqRange.lowerBound))
        let bHi = max(bLo, bin(min(sampleRate / 2, freqRange.upperBound)))

        var best: Float = -.greatestFiniteMagnitude
        var bestColumn = cLo, bestBin = bLo
        for c in cLo...cHi {
            let base = c * bins
            for b in bLo...bHi {
                let v = magnitudes[base + b]
                if v > best { best = v; bestColumn = c; bestBin = b }
            }
        }
        guard best.isFinite else { return nil }
        let frequency = Double(bestBin) * sampleRate / Double(fftSize)
        let time = (Double(bestColumn) + 0.5) / Double(columns) * duration
        return (time, frequency, Double(best))
    }
}

/// Owns the asynchronous amplitude-statistics computation for the current
/// selection. The latest request wins; stale results are dropped by token.
@MainActor
final class MeasurementModel: ObservableObject {
    @Published private(set) var stats: AmplitudeStats?
    @Published private(set) var isComputing = false

    private var token = 0
    private var task: Task<Void, Never>?

    /// Compute amplitude stats for `timeRange` of `url`, superseding any pending
    /// request. Results land back on the main actor.
    func compute(url: URL, timeRange: ClosedRange<Double>) {
        task?.cancel()
        token += 1
        let current = token
        isComputing = true
        stats = nil
        let lo = timeRange.lowerBound
        let hi = timeRange.upperBound
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let result = try? AudioStatsAnalyzer.analyze(url: url, startTime: lo, endTime: hi)
            await MainActor.run {
                guard let self, current == self.token else { return }
                self.isComputing = false
                self.stats = result
            }
        }
    }

    /// Discard the current result and cancel any in-flight computation.
    func clear() {
        task?.cancel()
        token += 1
        isComputing = false
        stats = nil
    }
}
