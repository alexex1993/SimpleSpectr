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
/// Used by the PNG export, which lays everything out in a single coordinate
/// space. The live scene composes the pieces below directly so it can pin the
/// frequency labels while the time axis scrolls/zooms.
struct SpectrogramAxes: View {
    let result: SpectrogramResult
    let plot: CGRect

    var body: some View {
        FrequencyAxisContent(result: result, plot: plot, showLabels: true, showGridlines: true)
        TimeAxisLabels(result: result, plot: plot)
    }
}

/// Frequency axis for the whole plot. In a stacked layout the plot rect is split
/// into equal panes (left channel on top, right below) and the axis is drawn once
/// per pane, with a separator line and an L/R badge marking each one.
/// `showLabels` / `showGridlines` let callers split labels (pinned gutter) from
/// gridlines (over the scrolling image).
struct FrequencyAxisContent: View {
    let result: SpectrogramResult
    let plot: CGRect
    var showLabels: Bool = true
    var showGridlines: Bool = true

    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        let panes = result.paneCount
        ForEach(0..<panes, id: \.self) { pane in
            let rect = paneRect(pane, of: panes)
            PaneFrequencyAxis(result: result,
                              plot: rect,
                              showLabels: showLabels,
                              showGridlines: showGridlines,
                              // Half-height panes fit fewer labels before they collide.
                              tickCount: panes > 1 ? 3 : SpectrogramPlot.tickCount,
                              // A pane's 0 Hz label sits right on top of the next
                              // pane's Nyquist label, so drop it except at the very
                              // bottom of the plot.
                              skipBottomTick: pane < panes - 1)

            // Separator between stacked panes: the image itself has no gutter,
            // so the boundary is drawn here on top of the pixels.
            if showGridlines, pane > 0 {
                Path { p in
                    p.move(to: CGPoint(x: rect.minX, y: rect.minY))
                    p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                }
                .stroke(Color.white.opacity(0.45), lineWidth: 1)
            }

            if showLabels, panes > 1, let badge = paneLabel(pane) {
                Text(badge)
                    .font(.system(size: SpectrogramPlot.tickFontSize + 1, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    // The gutter is narrow and the channel name is localized
                    // ("Izquierdo", "Левый"…), so let a long one shrink rather
                    // than truncate to something unreadable.
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: SpectrogramPlot.leftInset - 8, alignment: .leading)
                    .position(x: (SpectrogramPlot.leftInset - 8) / 2, y: rect.minY + 7)
            }
        }
    }

    /// Vertical slice of `plot` occupied by a pane (index 0 = top).
    private func paneRect(_ index: Int, of count: Int) -> CGRect {
        guard count > 1 else { return plot }
        let h = plot.height / CGFloat(count)
        return CGRect(x: plot.minX, y: plot.minY + CGFloat(index) * h,
                      width: plot.width, height: h)
    }

    /// Channel badge for a stacked pane.
    private func paneLabel(_ index: Int) -> String? {
        guard result.paneLayout == .stackedStereo else { return nil }
        return index == 0 ? L("pane.left") : L("pane.right")
    }
}

/// The frequency axis of a single plot: evenly spaced Hz labels on a linear
/// scale, octave-C/A4 note labels plus faint gridlines on a logarithmic scale,
/// or evenly warped Hz ticks on the perceptual scales.
private struct PaneFrequencyAxis: View {
    let result: SpectrogramResult
    let plot: CGRect
    var showLabels: Bool = true
    var showGridlines: Bool = true
    var tickCount: Int = SpectrogramPlot.tickCount
    /// Drop the label at this pane's 0 Hz end (it would collide with the label at
    /// the top of the pane below).
    var skipBottomTick: Bool = false

    var body: some View {
        switch result.frequencyScale {
        case .linear:               linearAxis
        case .logarithmic:          logAxis
        case .mel, .bark, .erb:     perceptualAxis
        }
    }

    /// Evenly spaced Hz labels from DC to Nyquist (linear scale has no gridlines).
    @ViewBuilder
    private var linearAxis: some View {
        if showLabels {
            let ticks = max(1, tickCount)
            ForEach(0...ticks, id: \.self) { i in
                if !(skipBottomTick && i == 0) {
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
        }
    }

    /// Perceptual scales (Mel/Bark/ERB): ticks evenly spaced in the warped axis
    /// (so equal screen distance = equal perceptual distance), each labelled with
    /// the real frequency at that height, plus faint gridlines.
    private var perceptualAxis: some View {
        let axis = result.frequencyAxis
        let ticks = max(1, tickCount)
        return ForEach(0...ticks, id: \.self) { i in
            let frac = Double(i) / Double(ticks)
            let y = plot.maxY - CGFloat(frac) * plot.height
            let hz = axis.frequency(forFraction: frac)

            if showGridlines && i > 0 && i < ticks {
                Path { p in
                    p.move(to: CGPoint(x: plot.minX, y: y))
                    p.addLine(to: CGPoint(x: plot.maxX, y: y))
                }
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            }

            if showLabels, !(skipBottomTick && i == 0) {
                Text(AxisFormatting.hz(hz))
                    .font(.system(size: SpectrogramPlot.tickFontSize))
                    .foregroundStyle(SpectrogramPlot.axisColor)
                    .frame(width: SpectrogramPlot.leftInset - 8, alignment: .trailing)
                    .position(x: (SpectrogramPlot.leftInset - 8) / 2, y: y)
            }
        }
    }

    /// Note-labelled log axis: faint octave gridlines, C-name labels per octave,
    /// and an emphasized A4 (440 Hz) reference line.
    private var logAxis: some View {
        let axis = result.frequencyAxis
        let notes = axis.noteTicks()
        // A stacked pane is half height, so label every other octave to keep the
        // gutter readable; the gridlines themselves stay at full density.
        let labelStride = tickCount < SpectrogramPlot.tickCount ? 2 : 1
        return ForEach(Array(notes.enumerated()), id: \.element.midi) { item in
            let note = item.element
            let y = plot.maxY - CGFloat(note.frac) * plot.height
            let isRef = note.midi == MusicNotes.a4MIDI
            let labelled = isRef || item.offset % labelStride == 0

            if showGridlines {
                Path { p in
                    p.move(to: CGPoint(x: plot.minX, y: y))
                    p.addLine(to: CGPoint(x: plot.maxX, y: y))
                }
                .stroke(isRef ? Color.accentColor.opacity(0.30)
                              : Color.white.opacity(0.08),
                        lineWidth: 0.5)
            }

            if showLabels, labelled {
                HStack(spacing: 2) {
                    Text(MusicNotes.name(midi: note.midi))
                    if isRef {
                        Text(AxisFormatting.hz(note.freq))
                            .font(.system(size: SpectrogramPlot.tickFontSize - 1))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: SpectrogramPlot.tickFontSize,
                              weight: isRef ? .semibold : .regular))
                .foregroundStyle(isRef ? Color.accentColor : SpectrogramPlot.axisColor)
                .frame(width: SpectrogramPlot.leftInset - 8, alignment: .trailing)
                .position(x: (SpectrogramPlot.leftInset - 8) / 2, y: y)
            }
        }
    }
}

/// Time (x) labels along the bottom of `plot`. `tickCount` can be raised when
/// the plot is zoomed so labels stay dense enough to read.
struct TimeAxisLabels: View {
    let result: SpectrogramResult
    let plot: CGRect
    var tickCount: Int = SpectrogramPlot.tickCount

    var body: some View {
        let ticks = max(1, tickCount)
        ForEach(0...ticks, id: \.self) { i in
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

private extension FrequencyAxis {
    /// Octave-C (plus A4) ticks that fall inside this axis' [min, max] range,
    /// each resolved to its vertical fraction (0…1, bottom…top). Used to draw
    /// the log-frequency gridlines and note-name labels.
    func noteTicks() -> [(midi: Int, freq: Double, frac: Double)] {
        guard minFrequency > 0, maxFrequency > minFrequency else { return [] }
        let midiLo = max(0, Int(ceil(69 + 12 * log2(minFrequency / MusicNotes.a4Frequency))))
        let midiHi = Int(floor(69 + 12 * log2(maxFrequency / MusicNotes.a4Frequency)))
        guard midiHi >= midiLo else { return [] }
        return (midiLo...midiHi).compactMap { midi in
            // Label each octave C and the A4 reference; skip everything else.
            guard midi % 12 == 0 || midi == MusicNotes.a4MIDI else { return nil }
            let f = MusicNotes.frequency(midi: midi)
            let frac = fraction(forFrequency: f)
            guard frac >= 0.001, frac <= 0.999 else { return nil }
            return (midi, f, frac)
        }
    }
}
