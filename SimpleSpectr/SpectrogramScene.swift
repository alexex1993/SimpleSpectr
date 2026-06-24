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
    @ObservedObject var player: AudioPlayerController

    @ObservedObject private var l10n = LocalizationManager.shared
    @State private var hover: (time: Double, frequency: Double, db: Double)?
    @State private var cursor: CGPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            GeometryReader { geo in
                let plot = SpectrogramPlot.frame(available: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(decorative: result.image, scale: 1.0)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: plot.width, height: plot.height)
                        .offset(x: plot.minX, y: plot.minY)

                    SpectrogramAxes(result: result, plot: plot)
                    playhead(in: plot)
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
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in seekToPoint(value.location, plot: plot) }
                )
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

    /// Click/drag on the plot seeks the audio to the time under the pointer,
    /// keeping the playhead in sync with the spectrogram.
    private func seekToPoint(_ point: CGPoint, plot: CGRect) {
        guard player.isReady, plot.width > 0, result.duration > 0 else { return }
        let fx = (point.x - plot.minX) / plot.width
        let t = Double(min(max(fx, 0), 1)) * result.duration
        player.seek(to: t)
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

    /// Vertical playhead that follows audio playback position.
    @ViewBuilder
    private func playhead(in plot: CGRect) -> some View {
        if player.isReady, plot.height > 0, plot.width > 0, result.duration > 0 {
            let frac = min(max(player.currentTime / result.duration, 0), 1)
            let x = plot.minX + CGFloat(frac) * plot.width
            Path { p in
                p.move(to: CGPoint(x: x, y: plot.minY))
                p.addLine(to: CGPoint(x: x, y: plot.maxY))
            }
            .stroke(Color.accentColor, lineWidth: 1.2)
            .shadow(color: .black.opacity(0.4), radius: 1)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func readout(in plot: CGRect) -> some View {
        if let h = hover, let c = cursor {
            VStack(alignment: .leading, spacing: 2) {
                readoutRow(L("readout.time"), formatTimeMS(h.time))
                readoutRow(L("readout.frequency"), formatFreq(h.frequency))
                readoutRow(L("readout.signal"), L("unit.db", h.db))
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

    /// Header duration: seconds with one decimal below a minute, otherwise m:ss.
    private func formatHeaderDuration(_ seconds: Double) -> String {
        if seconds < 60 { return L("unit.seconds", seconds) }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func formatTimeMS(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = seconds - Double(m * 60)
        return String(format: "%d:%05.2f", m, s)
    }

    private func formatFreq(_ hz: Double) -> String {
        hz >= 1000 ? L("unit.khz", hz / 1000) : L("unit.hz", hz)
    }
}
