//
//  SpectrumSliceView.swift
//  SimpleSpectr
//
//  Spectral slice ("spectrum slice"): a 1-D amplitude-vs-frequency plot of a
//  single STFT column, opened by double-clicking a time point on the
//  spectrogram (as in Audition / Acoustica). Reads the cached dB grid in
//  `SpectrogramResult`, so no audio is re-decoded. Frequency runs left→right on
//  the same linear/log scale as the spectrogram; amplitude (dB) runs bottom→top.
//

import SwiftUI

/// Identifies the time column whose spectrum is shown in the slice panel.
struct SpectrumSlice: Identifiable, Equatable {
    let id = UUID()
    let column: Int
    let time: Double
}

extension SpectrogramResult {
    /// Resolve a horizontal plot fraction (0…1) to the STFT column under it and
    /// the centre time of that column. Returns nil when there is no data.
    func slice(atFractionX fx: Double) -> SpectrumSlice? {
        guard columns > 0, duration > 0 else { return nil }
        let column = min(max(Int(fx * Double(columns)), 0), columns - 1)
        let time = (Double(column) + 0.5) / Double(columns) * duration
        return SpectrumSlice(column: column, time: time)
    }

    /// Loudest bin in a column → its frequency and dB.
    func peakBin(inColumn column: Int) -> (frequency: Double, db: Double)? {
        guard column >= 0, column < columns, bins > 0, fftSize > 0 else { return nil }
        let base = column * bins
        var best: Float = -.greatestFiniteMagnitude
        var bestBin = 0
        for b in 0..<bins where magnitudes[base + b] > best {
            best = magnitudes[base + b]
            bestBin = b
        }
        guard best.isFinite else { return nil }
        return (Double(bestBin) * sampleRate / Double(fftSize), Double(best))
    }
}

/// Floating panel that draws the amplitude spectrum of one time column.
struct SpectrumSliceView: View {
    let result: SpectrogramResult
    let slice: SpectrumSlice
    var onClose: () -> Void

    @ObservedObject private var l10n = LocalizationManager.shared
    /// Hovered point inside the plot, resolved to (frequency, dB).
    @State private var probe: (frequency: Double, db: Double)?

    // Inner plot gutters for the dB (left) and frequency (bottom) labels.
    private let gutterLeft: CGFloat = 40
    private let gutterBottom: CGFloat = 16
    private let gutterTop: CGFloat = 6
    private let gutterRight: CGFloat = 8

    private var axis: FrequencyAxis { result.frequencyAxis }
    private var minDB: Double { result.minDB }
    private var maxDB: Double { result.maxDB }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            plot
                .frame(width: 300, height: 168)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(width: 320)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.15)))
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.and.magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
            Text(L("slice.title"))
                .font(.system(size: 11, weight: .semibold))
            Spacer()
            Text(formatTime(slice.time))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(L("slice.close"))
        }
    }

    private var plot: some View {
        GeometryReader { geo in
            let area = CGRect(x: gutterLeft, y: gutterTop,
                              width: max(1, geo.size.width - gutterLeft - gutterRight),
                              height: max(1, geo.size.height - gutterTop - gutterBottom))
            ZStack(alignment: .topLeading) {
                grid(in: area)
                curve(in: area)
                peakMarker(in: area)
                probeMarker(in: area)
                dbLabels(in: area)
                freqLabels(in: area)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): updateProbe(at: p, area: area)
                case .ended: probe = nil
                }
            }
        }
    }

    // MARK: - Geometry helpers

    /// Frequency (Hz) → x in the plot area (respects linear/log scale).
    private func x(_ freq: Double, in area: CGRect) -> CGFloat {
        let frac = axis.fraction(forFrequency: freq)
        return area.minX + CGFloat(min(max(frac, 0), 1)) * area.width
    }

    /// dB → y in the plot area (top = maxDB, bottom = minDB).
    private func y(_ db: Double, in area: CGRect) -> CGFloat {
        let span = max(1e-6, maxDB - minDB)
        let frac = (db - minDB) / span
        return area.maxY - CGFloat(min(max(frac, 0), 1)) * area.height
    }

    // MARK: - Layers

    private func grid(in area: CGRect) -> some View {
        Path { p in
            p.addRect(area)
            // Horizontal dB gridlines every 20 dB below the peak.
            var db = (maxDB / 20).rounded(.down) * 20
            while db >= minDB {
                let gy = y(db, in: area)
                p.move(to: CGPoint(x: area.minX, y: gy))
                p.addLine(to: CGPoint(x: area.maxX, y: gy))
                db -= 20
            }
        }
        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
    }

    private func curve(in area: CGRect) -> some View {
        let pts = points(in: area)
        return ZStack {
            if pts.count > 1 {
                // Soft fill under the curve.
                Path { p in
                    p.move(to: CGPoint(x: pts[0].x, y: area.maxY))
                    for pt in pts { p.addLine(to: pt) }
                    p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: area.maxY))
                    p.closeSubpath()
                }
                .fill(Color.accentColor.opacity(0.18))

                Path { p in
                    p.move(to: pts[0])
                    for pt in pts.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(Color.accentColor, lineWidth: 1)
            }
        }
        .clipped()
    }

    /// One screen point per bin (skipping bins that fall left of the log axis).
    private func points(in area: CGRect) -> [CGPoint] {
        guard result.bins > 0, result.fftSize > 0 else { return [] }
        let base = slice.column * result.bins
        var pts: [CGPoint] = []
        pts.reserveCapacity(result.bins)
        for b in 0..<result.bins {
            let freq = Double(b) * result.sampleRate / Double(result.fftSize)
            let frac = axis.fraction(forFrequency: freq)
            if frac < 0 { continue }            // below the log axis floor
            if frac > 1 { break }
            let db = Double(result.magnitudes[base + b])
            pts.append(CGPoint(x: area.minX + CGFloat(frac) * area.width,
                               y: y(db, in: area)))
        }
        return pts
    }

    @ViewBuilder
    private func peakMarker(in area: CGRect) -> some View {
        if let peak = result.peakBin(inColumn: slice.column), peak.db.isFinite {
            let px = x(peak.frequency, in: area)
            let py = y(peak.db, in: area)
            ZStack {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 5, height: 5)
                    .position(x: px, y: py)
                Text(String(format: "%@ · %@",
                            formatFreq(peak.frequency), L("unit.db", peak.db)))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.orange)
                    .fixedSize()
                    .position(x: min(max(px, area.minX + 40), area.maxX - 40),
                              y: max(area.minY + 7, py - 9))
            }
        }
    }

    @ViewBuilder
    private func probeMarker(in area: CGRect) -> some View {
        if let pr = probe {
            let px = x(pr.frequency, in: area)
            Path { p in
                p.move(to: CGPoint(x: px, y: area.minY))
                p.addLine(to: CGPoint(x: px, y: area.maxY))
            }
            .stroke(Color.white.opacity(0.4), lineWidth: 0.5)

            Text(String(format: "%@ · %@", formatFreq(pr.frequency), L("unit.db", pr.db)))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                .fixedSize()
                .position(x: min(max(px, area.minX + 36), area.maxX - 36),
                          y: area.minY + 7)
        }
    }

    private func dbLabels(in area: CGRect) -> some View {
        var labels: [Double] = []
        var db = (maxDB / 20).rounded(.down) * 20
        while db >= minDB { labels.append(db); db -= 20 }
        return ForEach(labels, id: \.self) { value in
            Text(String(format: "%.0f", value))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(SpectrogramPlot.axisColor)
                .frame(width: gutterLeft - 6, alignment: .trailing)
                .position(x: (gutterLeft - 6) / 2, y: y(value, in: area))
        }
    }

    private func freqLabels(in area: CGRect) -> some View {
        let ticks = freqTicks()
        return ForEach(ticks, id: \.self) { freq in
            Text(AxisFormatting.hz(freq))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(SpectrogramPlot.axisColor)
                .fixedSize()
                .position(x: x(freq, in: area), y: area.maxY + gutterBottom / 2 + 2)
        }
    }

    /// Frequency tick positions: octave-spaced on a log axis, evenly spaced on a
    /// linear one.
    private func freqTicks() -> [Double] {
        let maxF = result.maxFrequency
        switch result.frequencyScale {
        case .linear:
            return (0...4).map { Double($0) / 4 * maxF }
        case .logarithmic:
            var out: [Double] = []
            var f = axis.minFrequency
            while f <= maxF {
                out.append(f)
                f *= 4   // two octaves apart so labels don't crowd
            }
            return out
        }
    }

    // MARK: - Hover

    private func updateProbe(at p: CGPoint, area: CGRect) {
        guard area.width > 0, p.x >= area.minX, p.x <= area.maxX,
              p.y >= area.minY, p.y <= area.maxY, result.bins > 0 else {
            probe = nil
            return
        }
        let frac = Double((p.x - area.minX) / area.width)
        let freq = axis.frequency(forFraction: frac)
        let bin = min(max(Int((freq * Double(result.fftSize) / result.sampleRate).rounded()), 0),
                      result.bins - 1)
        let db = Double(result.magnitudes[slice.column * result.bins + bin])
        probe = (Double(bin) * result.sampleRate / Double(result.fftSize), db)
    }

    // MARK: - Formatting

    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = seconds - Double(m * 60)
        return String(format: "%d:%05.2f", m, s)
    }

    private func formatFreq(_ hz: Double) -> String {
        hz >= 1000 ? L("unit.khz", hz / 1000) : L("unit.hz", hz)
    }
}
