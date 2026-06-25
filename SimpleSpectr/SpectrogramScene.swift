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
    let url: URL
    let result: SpectrogramResult
    @ObservedObject var player: AudioPlayerController
    @ObservedObject var markers: MarkersStore
    @Binding var zoom: CGFloat

    @ObservedObject private var l10n = LocalizationManager.shared
    @ObservedObject private var render = RenderPreferences.shared
    @StateObject private var measurement = MeasurementModel()
    @State private var hover: (time: Double, frequency: Double, db: Double)?
    @State private var cursor: CGPoint?
    @State private var measureMode = false
    @State private var selection: PlotSelection?
    @FocusState private var focused: Bool

    static let minZoom: CGFloat = 1
    static let maxZoom: CGFloat = 32
    static let zoomStep: CGFloat = 1.6
    static let seekStep: Double = 5   // seconds for ←/→

    /// Height of the overview waveform lane and its gap to the spectrogram.
    static let waveLaneHeight: CGFloat = 56
    static let waveLaneGap: CGFloat = 6
    /// Overtones drawn by the harmonic cursor (×2…×N of the hovered frequency).
    static let harmonicCount = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            GeometryReader { geo in
                let topInset = SpectrogramPlot.topInset
                let waveH: CGFloat = render.showWaveform ? Self.waveLaneHeight : 0
                let waveGap: CGFloat = render.showWaveform ? Self.waveLaneGap : 0
                let plotTop = topInset + waveH + waveGap
                let plotHeight = max(0, geo.size.height - plotTop - SpectrogramPlot.bottomInset)
                let visibleWidth = max(0, geo.size.width - SpectrogramPlot.leftInset - SpectrogramPlot.rightInset)
                let contentWidth = max(visibleWidth, visibleWidth * zoom)
                // Plot rect inside the scrolling content (origin top-left of content).
                let content = CGRect(x: 0, y: plotTop, width: contentWidth, height: plotHeight)
                // Full vertical span the playhead / markers cover (wave lane + plot).
                let band = CGRect(x: 0, y: topInset, width: contentWidth, height: waveH + waveGap + plotHeight)

                HStack(spacing: 0) {
                    // Pinned frequency axis gutter. The Color.clear gives the
                    // positioned labels a concrete full-height coordinate space
                    // (otherwise `.position` collapses and the labels stack).
                    ZStack(alignment: .topLeading) {
                        Color.clear
                        FrequencyAxisContent(
                            result: result,
                            plot: CGRect(x: 0, y: plotTop, width: SpectrogramPlot.leftInset, height: plotHeight),
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
                                .offset(x: 0, y: plotTop)

                            if render.showWaveform {
                                waveformLane(width: contentWidth, height: waveH, top: topInset)
                            }

                            // Log-scale gridlines span the (zoomed) image width.
                            FrequencyAxisContent(result: result, plot: content,
                                                 showLabels: false, showGridlines: true)
                            TimeAxisLabels(result: result, plot: content, tickCount: timeTicks)
                            playhead(in: band)
                            markerFlags(in: band)
                            selectionOverlay(in: content)
                            crosshair(in: content)
                            if render.showHarmonics { harmonicCursor(in: content) }
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
                                    if measureMode {
                                        updateSelection(start: value.startLocation,
                                                        current: value.location, content: content)
                                    } else {
                                        seekToPoint(value.location, content: content)
                                    }
                                }
                                .onEnded { _ in
                                    if measureMode { finalizeSelection() }
                                }
                        )
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if measureMode, let sel = selection, sel.isMeaningful {
                        measurementPanel(sel)
                            .padding(.trailing, SpectrogramPlot.rightInset + 6)
                            .padding(.bottom, SpectrogramPlot.bottomInset + 6)
                    }
                }
            }
        }
        .onChange(of: url) { _, _ in clearSelection() }
        .onChange(of: measureMode) { _, on in if !on { clearSelection() } }
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

    // MARK: - Measurement selection

    /// Resolve a point in content coordinates to a (time, frequency) pair.
    private func point(at p: CGPoint, content: CGRect) -> (time: Double, frequency: Double) {
        let fx = min(max(p.x / content.width, 0), 1)
        let fy = min(max((content.maxY - p.y) / content.height, 0), 1)
        return (Double(fx) * result.duration,
                result.frequencyAxis.frequency(forFraction: Double(fy)))
    }

    /// Update the live selection while dragging in measure mode.
    private func updateSelection(start: CGPoint, current: CGPoint, content: CGRect) {
        guard content.width > 0, content.height > 0, result.duration > 0 else { return }
        let a = point(at: start, content: content)
        let b = point(at: current, content: content)
        selection = PlotSelection(anchorTime: a.time, anchorFreq: a.frequency,
                                  focusTime: b.time, focusFreq: b.frequency)
    }

    /// Drag ended: kick off (or clear) the amplitude-stats computation.
    private func finalizeSelection() {
        guard let sel = selection, sel.isMeaningful else {
            clearSelection()
            return
        }
        measurement.compute(url: url, timeRange: sel.timeRange)
    }

    private func clearSelection() {
        selection = nil
        measurement.clear()
    }

    @ViewBuilder
    private func selectionOverlay(in content: CGRect) -> some View {
        if let sel = selection, sel.isMeaningful, result.duration > 0 {
            let axis = result.frequencyAxis
            let x0 = CGFloat(sel.timeRange.lowerBound / result.duration) * content.width
            let x1 = CGFloat(sel.timeRange.upperBound / result.duration) * content.width
            let yLow = content.maxY - CGFloat(axis.fraction(forFrequency: sel.freqRange.lowerBound)) * content.height
            let yHigh = content.maxY - CGFloat(axis.fraction(forFrequency: sel.freqRange.upperBound)) * content.height
            let rect = CGRect(x: x0, y: min(yLow, yHigh),
                              width: max(1, x1 - x0), height: max(1, abs(yLow - yHigh)))
            ZStack {
                Path { $0.addRect(rect) }
                    .fill(Color.accentColor.opacity(0.12))
                Path { $0.addRect(rect) }
                    .stroke(Color.accentColor.opacity(0.9),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .allowsHitTesting(false)
        }
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
            overlayToggles
            zoomControls
        }
    }

    /// Toggle the overview waveform lane, the harmonic cursor, and the pitch track.
    private var overlayToggles: some View {
        HStack(spacing: 4) {
            toggleButton(systemImage: "waveform.path",
                         isOn: render.showWaveform,
                         help: L("toggle.waveform")) { render.showWaveform.toggle() }
            toggleButton(systemImage: "lines.measurement.horizontal",
                         isOn: render.showHarmonics,
                         help: L("toggle.harmonics")) { render.showHarmonics.toggle() }
            toggleButton(systemImage: "rectangle.dashed",
                         isOn: measureMode,
                         help: L("toggle.measure")) { measureMode.toggle() }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13))
        .padding(.trailing, 4)
    }

    private func toggleButton(systemImage: String,
                              isOn: Bool,
                              help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
        }
        .help(help)
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

    /// Overview waveform lane: a filled peak envelope (min/max per column) with a
    /// faint zero line. Lined up 1:1 with the spectrogram's time columns above it.
    private func waveformLane(width: CGFloat, height: CGFloat, top: CGFloat) -> some View {
        Canvas { ctx, size in
            let cols = result.columns
            guard cols > 0, size.width > 0, size.height > 0 else { return }
            let mid = size.height / 2

            // Normalize to the loudest peak so quiet files still fill the lane.
            var peak: Float = 1e-6
            for i in 0..<cols { peak = max(peak, max(result.waveformMax[i], -result.waveformMin[i])) }
            let scale = Double(mid * 0.92) / Double(peak)

            func x(_ i: Int) -> CGFloat { (CGFloat(i) + 0.5) / CGFloat(cols) * size.width }
            func y(_ v: Float) -> CGFloat { mid - CGFloat(Double(v) * scale) }

            var env = Path()
            env.move(to: CGPoint(x: x(0), y: y(result.waveformMax[0])))
            for i in 1..<cols { env.addLine(to: CGPoint(x: x(i), y: y(result.waveformMax[i]))) }
            for i in stride(from: cols - 1, through: 0, by: -1) {
                env.addLine(to: CGPoint(x: x(i), y: y(result.waveformMin[i])))
            }
            env.closeSubpath()
            ctx.fill(env, with: .color(.white.opacity(0.5)))

            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: mid))
            zero.addLine(to: CGPoint(x: size.width, y: mid))
            ctx.stroke(zero, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
        }
        .frame(width: width, height: height)
        .background(Color.white.opacity(0.03))
        .offset(x: 0, y: top)
        .allowsHitTesting(false)
    }

    /// Harmonic cursor: faint horizontal lines at ×2…×N of the hovered frequency,
    /// labelled with the multiplier, to make an overtone series easy to read off.
    @ViewBuilder
    private func harmonicCursor(in content: CGRect) -> some View {
        if let h = hover, h.frequency > 0 {
            let axis = result.frequencyAxis
            ForEach(2...Self.harmonicCount, id: \.self) { n in
                let freq = h.frequency * Double(n)
                if freq <= result.maxFrequency {
                    let frac = axis.fraction(forFrequency: freq)
                    if frac >= 0, frac <= 1 {
                        let y = content.maxY - CGFloat(frac) * content.height
                        Path { p in
                            p.move(to: CGPoint(x: content.minX, y: y))
                            p.addLine(to: CGPoint(x: content.maxX, y: y))
                        }
                        .stroke(Color.orange.opacity(0.45),
                                style: StrokeStyle(lineWidth: 0.75, dash: [4, 3]))

                        Text("×\(n)")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.orange.opacity(0.9))
                            .position(x: content.minX + 12, y: y - 6)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

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

    // MARK: - Measurement panel

    /// Floating results card for the current selection: time/frequency deltas,
    /// the loudest bin in the region, and time-domain amplitude statistics.
    private func measurementPanel(_ sel: PlotSelection) -> some View {
        let peak = result.regionPeak(timeRange: sel.timeRange, freqRange: sel.freqRange)
        return VStack(alignment: .leading, spacing: 5) {
            Text(L("measure.title"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            measureRow(L("measure.deltaTime"), formatDeltaTime(sel.deltaTime))
            measureRow(L("measure.deltaFreq"), formatDeltaFreq(sel.deltaFreq))
            if let interval = pitchInterval(sel) {
                measureRow(L("measure.interval"), interval)
            }
            if let rate = rateFromDelta(sel.deltaTime) {
                measureRow(L("measure.rate"), rate)
            }

            Divider().overlay(Color.white.opacity(0.15))

            if let p = peak {
                measureRow(L("measure.peakFreq"), formatFreq(p.frequency))
                measureRow(L("measure.peakLevel"), L("unit.db", p.db))
            }

            Divider().overlay(Color.white.opacity(0.15))

            if measurement.isComputing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(L("measure.analyzing")).foregroundStyle(.secondary)
                }
                .font(.system(size: 10))
            } else if let s = measurement.stats {
                measureRow(L("measure.rms"), formatDB(s.rmsDBFS, "unit.dbfs"))
                measureRow(L("measure.peak"), formatDB(s.peakDBFS, "unit.dbfs"))
                measureRow(L("measure.truePeak"), formatDB(s.truePeakDBTP, "unit.dbtp"))
                measureRow(L("measure.lufs"), formatDB(s.lufs, "unit.lufs"))
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(width: 196, alignment: .leading)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.15)))
    }

    private func measureRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(.white).monospacedDigit()
        }
    }

    /// Signed time delta: ms below a second, else seconds with sign.
    private func formatDeltaTime(_ dt: Double) -> String {
        let a = abs(dt)
        let sign = dt < 0 ? "−" : ""
        if a < 1 { return String(format: "%@%.1f ms", sign, a * 1000) }
        return String(format: "%@%.3f s", sign, a)
    }

    private func formatDeltaFreq(_ df: Double) -> String {
        let a = abs(df)
        let sign = df < 0 ? "−" : ""
        return a >= 1000 ? String(format: "%@%.2f kHz", sign, a / 1000)
                         : String(format: "%@%.1f Hz", sign, a)
    }

    /// Musical interval between the two selected frequencies (semitones + ratio).
    private func pitchInterval(_ sel: PlotSelection) -> String? {
        let lo = sel.freqRange.lowerBound, hi = sel.freqRange.upperBound
        guard lo > 0, hi > lo else { return nil }
        let semitones = 12 * log2(hi / lo)
        return String(format: "%.2f st · %.3f×", semitones, hi / lo)
    }

    /// Reading a periodic spacing off the time delta: its frequency and tempo.
    private func rateFromDelta(_ dt: Double) -> String? {
        let a = abs(dt)
        guard a > 1e-5 else { return nil }
        let hz = 1.0 / a
        return String(format: "%@ · %.1f BPM", formatFreq(hz), hz * 60)
    }

    /// dB value with a unit key, or an em dash when undefined (silence / too short).
    private func formatDB(_ value: Double, _ unitKey: String) -> String {
        value.isFinite ? L(unitKey, value) : "—"
    }
}
