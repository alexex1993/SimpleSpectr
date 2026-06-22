//
//  SpectrogramScene.swift
//  SimpleSpectr
//
//  Displays a computed spectrogram with time (x) and frequency (y) axes.
//

import SwiftUI

struct SpectrogramScene: View {
    let name: String
    let result: SpectrogramResult

    @State private var hover: (time: Double, frequency: Double, db: Double)?
    @State private var cursor: CGPoint?

    private let axisColor = Color(white: 0.6)
    private let leftInset: CGFloat = 56
    private let bottomInset: CGFloat = 28
    private let topInset: CGFloat = 8
    private let rightInset: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            GeometryReader { geo in
                let plot = CGRect(x: leftInset,
                                  y: topInset,
                                  width: max(0, geo.size.width - leftInset - rightInset),
                                  height: max(0, geo.size.height - topInset - bottomInset))
                ZStack(alignment: .topLeading) {
                    Image(decorative: result.image, scale: 1.0)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: plot.width, height: plot.height)
                        .offset(x: plot.minX, y: plot.minY)

                    axes(in: plot)
                    crosshair(in: plot)
                    readout(in: plot)
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        updateHover(at: point, plot: plot)
                    case .ended:
                        hover = nil
                        cursor = nil
                    }
                }
            }
        }
        .padding(12)
        .foregroundStyle(.white)
    }

    private func updateHover(at point: CGPoint, plot: CGRect) {
        guard plot.width > 0, plot.height > 0,
              plot.contains(point) else {
            hover = nil
            cursor = nil
            return
        }
        let fx = (point.x - plot.minX) / plot.width
        // View y grows downward; spectrogram fraction origin is bottom-left.
        let fy = (plot.maxY - point.y) / plot.height
        hover = result.sample(fractionX: Double(fx), fractionY: Double(fy))
        cursor = point
    }

    private var header: some View {
        HStack {
            Image(systemName: "waveform")
            Text(name).fontWeight(.semibold)
            Spacer()
            Text(String(format: "%.1f kHz · %@",
                        result.sampleRate / 1000,
                        formatHeaderDuration(result.duration)))
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    @ViewBuilder
    private func crosshair(in plot: CGRect) -> some View {
        if let c = cursor {
            Path { p in
                p.move(to: CGPoint(x: c.x, y: plot.minY))
                p.addLine(to: CGPoint(x: c.x, y: plot.maxY))
                p.move(to: CGPoint(x: plot.minX, y: c.y))
                p.addLine(to: CGPoint(x: plot.maxX, y: c.y))
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private func readout(in plot: CGRect) -> some View {
        if let h = hover, let c = cursor {
            VStack(alignment: .leading, spacing: 2) {
                readoutRow("Время", formatTimeMS(h.time))
                readoutRow("Частота", formatFreq(h.frequency))
                readoutRow("Сигнал", String(format: "%.1f дБ", h.db))
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.15)))
            .position(readoutPosition(cursor: c, plot: plot))
        }
    }

    /// Place the readout in the quadrant opposite the cursor so it never covers the crosshair.
    private func readoutPosition(cursor c: CGPoint, plot: CGRect) -> CGPoint {
        let halfW: CGFloat = 78
        let halfH: CGFloat = 32
        let x: CGFloat = c.x > plot.midX ? plot.minX + halfW : plot.maxX - halfW
        let y: CGFloat = c.y > plot.midY ? plot.minY + halfH : plot.maxY - halfH
        return CGPoint(x: x, y: y)
    }

    private func readoutRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(.white)
        }
        .frame(width: 124)
    }

    @ViewBuilder
    private func axes(in plot: CGRect) -> some View {
        // Frequency labels (y axis) — a few evenly spaced ticks.
        let freqTicks = 6
        ForEach(0...freqTicks, id: \.self) { i in
            let frac = Double(i) / Double(freqTicks)
            let y = plot.maxY - CGFloat(frac) * plot.height
            let hz = frac * result.maxFrequency
            Text(formatHz(hz))
                .font(.system(size: 9))
                .foregroundStyle(axisColor)
                .frame(width: leftInset - 8, alignment: .trailing)
                .position(x: (leftInset - 8) / 2, y: y)
        }

        // Time labels (x axis).
        let timeTicks = 6
        ForEach(0...timeTicks, id: \.self) { i in
            let frac = Double(i) / Double(timeTicks)
            let x = plot.minX + CGFloat(frac) * plot.width
            let t = frac * result.duration
            Text(formatDuration(t))
                .font(.system(size: 9))
                .foregroundStyle(axisColor)
                .position(x: x, y: plot.maxY + 14)
        }
    }

    private func formatHz(_ hz: Double) -> String {
        hz >= 1000 ? String(format: "%.0fk", hz / 1000) : String(format: "%.0f", hz)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    /// Header duration: seconds with one decimal below a minute, otherwise m:ss.
    private func formatHeaderDuration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.1f с", seconds) }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func formatTimeMS(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = seconds - Double(m * 60)
        return String(format: "%d:%05.2f", m, s)
    }

    private func formatFreq(_ hz: Double) -> String {
        hz >= 1000 ? String(format: "%.2f кГц", hz / 1000) : String(format: "%.0f Гц", hz)
    }
}
