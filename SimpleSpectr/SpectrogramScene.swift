//
//  SpectrogramScene.swift
//  SimpleSpectr
//
//  Displays a computed spectrogram with time (x) and frequency (y) axes.
//  The frequency axis is pinned in a left gutter while the plot itself scrolls
//  and zooms horizontally along the time axis. Keyboard shortcuts (space, ←/→,
//  +/-, M) are handled here while the plot has focus.
//

import SwiftUI

struct SpectrogramScene: View {
    let name: String
    let result: SpectrogramResult
    @ObservedObject var player: AudioPlayerController
    @ObservedObject var markers: MarkersStore
    @Binding var zoom: CGFloat

    @ObservedObject private var l10n = LocalizationManager.shared
    @State private var hover: (time: Double, frequency: Double, db: Double)?
    @State private var cursor: CGPoint?
    @FocusState private var focused: Bool

    static let minZoom: CGFloat = 1
    static let maxZoom: CGFloat = 32
    static let zoomStep: CGFloat = 1.6
    static let seekStep: Double = 5   // seconds for ←/→

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            GeometryReader { geo in
                let topInset = SpectrogramPlot.topInset
                let plotHeight = max(0, geo.size.height - topInset - SpectrogramPlot.bottomInset)
                let visibleWidth = max(0, geo.size.width - SpectrogramPlot.leftInset - SpectrogramPlot.rightInset)
                let contentWidth = max(visibleWidth, visibleWidth * zoom)
                // Plot rect inside the scrolling content (origin top-left of content).
                let content = CGRect(x: 0, y: topInset, width: contentWidth, height: plotHeight)

                HStack(spacing: 0) {
                    // Pinned frequency axis gutter. The Color.clear gives the
                    // positioned labels a concrete full-height coordinate space
                    // (otherwise `.position` collapses and the labels stack).
                    ZStack(alignment: .topLeading) {
                        Color.clear
                        FrequencyAxisContent(
                            result: result,
                            plot: CGRect(x: 0, y: topInset, width: SpectrogramPlot.leftInset, height: plotHeight),
                            showLabels: true,
                            showGridlines: false)
                    }
                    .frame(width: SpectrogramPlot.leftInset, height: geo.size.height)

                    // Scrollable / zoomable plot.
                    ScrollView(.horizontal, showsIndicators: true) {
                        ZStack(alignment: .topLeading) {
                            Image(decorative: result.image, scale: 1.0)
                                .resizable()
                                .interpolation(.medium)
                                .frame(width: contentWidth, height: plotHeight)
                                .offset(x: 0, y: topInset)

                            // Log-scale gridlines span the (zoomed) image width.
                            FrequencyAxisContent(result: result, plot: content,
                                                 showLabels: false, showGridlines: true)
                            TimeAxisLabels(result: result, plot: content, tickCount: timeTicks)
                            playhead(in: content)
                            markerFlags(in: content)
                            crosshair(in: content)
                            readout(in: content)
                        }
                        .frame(width: contentWidth, height: geo.size.height, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                updateHover(at: point, content: content)
                            case .ended:
                                hover = nil
                                cursor = nil
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    focused = true
                                    seekToPoint(value.location, content: content)
                                }
                        )
                    }
                }
            }
        }
        .padding(12)
        .foregroundStyle(.white)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress { handleKey($0) }
    }

    // MARK: - Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .space:
            player.togglePlayPause(); return .handled
        case .leftArrow:
            seekRelative(-Self.seekStep); return .handled
        case .rightArrow:
            seekRelative(Self.seekStep); return .handled
        default:
            break
        }
        switch press.characters {
        case "+", "=":
            zoomBy(Self.zoomStep); return .handled
        case "-", "_":
            zoomBy(1 / Self.zoomStep); return .handled
        case "m", "M":
            addMarkerAtPlayhead(); return .handled
        default:
            return .ignored
        }
    }

    private func seekRelative(_ delta: Double) {
        guard player.isReady else { return }
        player.seek(to: player.currentTime + delta)
    }

    private func zoomBy(_ factor: CGFloat) {
        zoom = min(max(zoom * factor, Self.minZoom), Self.maxZoom)
    }

    private func addMarkerAtPlayhead() {
        let t = player.isReady ? player.currentTime : (hover?.time ?? 0)
        markers.add(at: t)
    }

    /// Time-axis ticks scale with zoom so labels stay readable when stretched.
    private var timeTicks: Int {
        min(40, Int((CGFloat(SpectrogramPlot.tickCount) * zoom).rounded()))
    }

    // MARK: - Hover / seek

    private func updateHover(at point: CGPoint, content: CGRect) {
        let top = content.minY
        let bottom = content.maxY
        guard content.width > 0, content.height > 0,
              point.x >= 0, point.x <= content.width,
              point.y >= top, point.y <= bottom else {
            hover = nil
            cursor = nil
            return
        }
        let fx = point.x / content.width
        // View y grows downward; spectrogram fraction origin is bottom-left.
        let fy = (bottom - point.y) / content.height
        hover = result.sample(fractionX: Double(fx), fractionY: Double(fy))
        cursor = point
    }

    /// Click/drag on the plot seeks the audio to the time under the pointer.
    private func seekToPoint(_ point: CGPoint, content: CGRect) {
        guard player.isReady, content.width > 0, result.duration > 0 else { return }
        let fx = point.x / content.width
        let t = Double(min(max(fx, 0), 1)) * result.duration
        player.seek(to: t)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
            Text(name).fontWeight(.semibold).lineLimit(1)
            Spacer()
            Text(String(format: "%.1f kHz · %@",
                        result.sampleRate / 1000,
                        formatHeaderDuration(result.duration)))
                .foregroundStyle(.secondary)
                .font(.callout)
            zoomControls
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button { zoomBy(1 / Self.zoomStep) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(zoom <= Self.minZoom + 0.001)
            .help(L("menu.zoomOut"))

            Text(String(format: "%.0f×", zoom))
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 28)

            Button { zoomBy(Self.zoomStep) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(zoom >= Self.maxZoom - 0.001)
            .help(L("menu.zoomIn"))

            Button { zoom = Self.minZoom } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .disabled(zoom <= Self.minZoom + 0.001)
            .help(L("menu.zoomReset"))
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13))
    }

    // MARK: - Overlays

    @ViewBuilder
    private func crosshair(in content: CGRect) -> some View {
        if let c = cursor {
            Path { p in
                p.move(to: CGPoint(x: c.x, y: content.minY))
                p.addLine(to: CGPoint(x: c.x, y: content.maxY))
                p.move(to: CGPoint(x: 0, y: c.y))
                p.addLine(to: CGPoint(x: content.maxX, y: c.y))
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
            .allowsHitTesting(false)
        }
    }

    /// Vertical playhead that follows audio playback position.
    @ViewBuilder
    private func playhead(in content: CGRect) -> some View {
        if player.isReady, content.height > 0, content.width > 0, result.duration > 0 {
            let frac = min(max(player.currentTime / result.duration, 0), 1)
            let x = CGFloat(frac) * content.width
            Path { p in
                p.move(to: CGPoint(x: x, y: content.minY))
                p.addLine(to: CGPoint(x: x, y: content.maxY))
            }
            .stroke(Color.accentColor, lineWidth: 1.2)
            .shadow(color: .black.opacity(0.4), radius: 1)
            .allowsHitTesting(false)
        }
    }

    /// Vertical lines + label flags for each session marker.
    @ViewBuilder
    private func markerFlags(in content: CGRect) -> some View {
        if result.duration > 0, content.width > 0 {
            ForEach(markers.markers) { marker in
                let frac = min(max(marker.time / result.duration, 0), 1)
                let x = CGFloat(frac) * content.width
                ZStack(alignment: .topLeading) {
                    Path { p in
                        p.move(to: CGPoint(x: x, y: content.minY))
                        p.addLine(to: CGPoint(x: x, y: content.maxY))
                    }
                    .stroke(Color.yellow.opacity(0.85), lineWidth: 1)

                    Text(marker.label)
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.yellow.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.black)
                        .fixedSize()
                        .offset(x: x + 2, y: content.minY + 1)
                }
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func readout(in content: CGRect) -> some View {
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
            .position(readoutPosition(cursor: c, content: content))
            .allowsHitTesting(false)
        }
    }

    /// Place the readout in the quadrant opposite the cursor so it never covers
    /// the crosshair. Clamped near the cursor so it stays on screen when zoomed.
    private func readoutPosition(cursor c: CGPoint, content: CGRect) -> CGPoint {
        let halfW: CGFloat = 78
        let halfH: CGFloat = 32
        let x: CGFloat = c.x > content.midX
            ? max(content.minX + halfW, c.x - 120)
            : min(content.maxX - halfW, c.x + 120)
        let y: CGFloat = c.y > content.midY ? content.minY + halfH : content.maxY - halfH
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

    // MARK: - Formatting

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
