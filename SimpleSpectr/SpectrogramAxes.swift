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
/// On a logarithmic frequency axis, octave-C gridlines and note names (plus the
/// A4 = 440 Hz reference) are drawn instead of evenly spaced Hz ticks.
struct SpectrogramAxes: View {
    let result: SpectrogramResult
    let plot: CGRect

    var body: some View {
        frequencyAxis
        timeAxis
    }

    @ViewBuilder
    private var frequencyAxis: some View {
        switch result.frequencyScale {
        case .linear:      linearFrequencyAxis
        case .logarithmic: logFrequencyAxis
        }
    }

    /// Evenly spaced Hz ticks from DC to Nyquist.
    private var linearFrequencyAxis: some View {
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

    /// Note-labelled log axis: faint octave gridlines, C-name labels per octave,
    /// and an emphasized A4 (440 Hz) reference line.
    private var logFrequencyAxis: some View {
        let axis = result.frequencyAxis
        let notes = axis.noteTicks()
        return ForEach(notes, id: \.midi) { note in
            let y = plot.maxY - CGFloat(note.frac) * plot.height
            let isRef = note.midi == MusicNotes.a4MIDI
            Path { p in
                p.move(to: CGPoint(x: plot.minX, y: y))
                p.addLine(to: CGPoint(x: plot.maxX, y: y))
            }
            .stroke(isRef ? Color.accentColor.opacity(0.30)
                          : Color.white.opacity(0.08),
                    lineWidth: 0.5)

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
