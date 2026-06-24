//
//  SpectrogramAxes.swift
//  SimpleSpectr
//
//  Shared plot metrics, axis rendering and axis value formatting used by both
//  the on-screen SpectrogramScene and the PNG export view.
//

import SwiftUI

/// Layout constants shared by every spectrogram rendering (live view + export).
enum SpectrogramPlot {
    static let leftInset: CGFloat = 56
    static let bottomInset: CGFloat = 28
    static let topInset: CGFloat = 8
    static let rightInset: CGFloat = 12

    static let axisColor = Color(white: 0.6)
    static let tickCount = 6
    static let tickFontSize: CGFloat = 9
    static let timeAxisOffset: CGFloat = 14

    /// Outer padding applied around the whole plot region.
    static func frame(available size: CGSize) -> CGRect {
        CGRect(x: leftInset,
               y: topInset,
               width: max(0, size.width - leftInset - rightInset),
               height: max(0, size.height - topInset - bottomInset))
    }
}

/// Frequency (y) and time (x) axes drawn over `plot` for `result`.
/// Low frequencies sit at the bottom, high at the top; time runs left → right.
struct SpectrogramAxes: View {
    let result: SpectrogramResult
    let plot: CGRect

    var body: some View {
        frequencyAxis
        timeAxis
    }

    private var frequencyAxis: some View {
        let ticks = SpectrogramPlot.tickCount
        return ForEach(0...ticks, id: \.self) { i in
            let frac = Double(i) / Double(ticks)
            let y = plot.maxY - CGFloat(frac) * plot.height
            let hz = frac * result.maxFrequency
            Text(AxisFormatting.hz(hz))
                .font(.system(size: SpectrogramPlot.tickFontSize))
                .foregroundStyle(SpectrogramPlot.axisColor)
                .frame(width: SpectrogramPlot.leftInset - 8, alignment: .trailing)
                .position(x: (SpectrogramPlot.leftInset - 8) / 2, y: y)
        }
    }

    private var timeAxis: some View {
        let ticks = SpectrogramPlot.tickCount
        return ForEach(0...ticks, id: \.self) { i in
            let frac = Double(i) / Double(ticks)
            let x = plot.minX + CGFloat(frac) * plot.width
            let t = frac * result.duration
            Text(AxisFormatting.duration(t))
                .font(.system(size: SpectrogramPlot.tickFontSize))
                .foregroundStyle(SpectrogramPlot.axisColor)
                .position(x: x, y: plot.maxY + SpectrogramPlot.timeAxisOffset)
        }
    }
}

/// Plain (non-localized) axis value formatting, shared by the axes and the
/// player bar. Localized formatting (e.g. "Hz"/"kHz" labels, seconds with
/// units) stays in the views that present it.
enum AxisFormatting {
    /// Compact frequency tick label: "1k" above 1 kHz, else whole hertz.
    static func hz(_ hz: Double) -> String {
        hz >= 1000 ? String(format: "%.0fk", hz / 1000) : String(format: "%.0f", hz)
    }

    /// `m:ss` duration from seconds (rounded).
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
