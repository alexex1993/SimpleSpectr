//
//  ContentView.swift
//  SimpleSpectr
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    /// Audio source the idle screen offers: open a file or record the mic.
    enum Source: Hashable { case file, microphone }

    @ObservedObject var model: SpectrogramModel
    /// Visibility of the trailing settings inspector (owned by the app so the
    /// View-menu command and the toolbar toggle share one source of truth).
    @Binding var showInspector: Bool
    @ObservedObject private var l10n = LocalizationManager.shared
    @ObservedObject private var render = RenderPreferences.shared
    @StateObject private var player = AudioPlayerController()
    @StateObject private var markers = MarkersStore()
    @StateObject private var recorder = AudioRecorderController()
    @State private var source: Source = .file
    @State private var showImporter = false
    @State private var isTargetedForDrop = false
    @State private var showExporter = false
    @State private var showRecordingExporter = false
    @State private var showInfo = false
    @State private var showMarkers = false
    @State private var zoom: CGFloat = 1

    /// The loaded spectrogram (image + source url + suggested file name), if any.
    private var loaded: (name: String, url: URL, result: SpectrogramResult)? {
        if case .loaded(let name, let url, let result) = model.state { return (name, url, result) }
        return nil
    }

    /// True when the loaded file is a microphone recording (drives "Save recording").
    private var isRecordingLoaded: Bool {
        guard let url = loaded?.url else { return false }
        return AudioRecorderController.isRecordingURL(url)
    }

    @ViewBuilder
    private var content: some View {
        if recorder.phase != .idle {
            RecordingView(recorder: recorder, onStop: stopRecording)
        } else {
            switch model.state {
            case .idle:
                IdlePrompt(source: $source,
                           isTargeted: isTargetedForDrop,
                           onOpen: { showImporter = true },
                           onRecord: startRecording)
            case .loading(let name):
                LoadingView(name: name)
            case .loaded(let name, let url, let result):
                VStack(spacing: 0) {
                    SpectrogramScene(name: name, url: url, result: result, player: player,
                                     playhead: player.playhead, markers: markers, zoom: $zoom)
                    Divider().overlay(Color.white.opacity(0.08))
                    PlayerBar(player: player, playhead: player.playhead)
                }
            case .failed(let message):
                FailureView(message: message) { showImporter = true }
            }
        }
    }

    var body: some View {
        ZStack {
            Color(white: 0.07).ignoresSafeArea()
            content
        }
        .frame(minWidth: 640, minHeight: 420)
        .inspector(isPresented: $showInspector) {
            SettingsView()
                .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker(L("settings.channel"), selection: $render.channelMode) {
                        ForEach(ChannelMode.allCases) { c in
                            Text(c.displayName).tag(c)
                        }
                    }
                    Picker(L("settings.magnitude"), selection: $render.magnitudeScale) {
                        ForEach(MagnitudeScale.allCases) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                } label: {
                    Label(L("button.viewOptions"), systemImage: "slider.horizontal.3")
                }
                .disabled(loaded == nil)
                .help(L("button.viewOptions"))
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInfo = true
                } label: {
                    Label(L("button.fileInfo"), systemImage: "info.circle")
                }
                .disabled(model.fileInfo == nil)
                .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                    if let info = model.fileInfo {
                        FileInfoPopover(info: info)
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showMarkers = true
                } label: {
                    Label(L("button.markers"), systemImage: "mappin.and.ellipse")
                }
                .disabled(loaded == nil)
                .popover(isPresented: $showMarkers, arrowEdge: .bottom) {
                    MarkersPopover(markers: markers,
                                   canAdd: player.isReady,
                                   onAdd: { markers.add(at: player.currentTime) })
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showRecordingExporter = true
                } label: {
                    Label(L("button.saveRecording"), systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(!isRecordingLoaded)
                .help(L("button.saveRecording"))
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showExporter = true
                } label: {
                    Label(L("button.export"), systemImage: "square.and.arrow.down")
                }
                .disabled(loaded == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    startRecording()
                } label: {
                    Label(L("button.record"), systemImage: "record.circle")
                }
                .disabled(recorder.phase == .recording)
                .help(L("button.record"))
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showImporter = true
                } label: {
                    Label(L("button.openAudio"), systemImage: "waveform")
                }
                .disabled(recorder.phase == .recording)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInspector.toggle()
                } label: {
                    Label(L("settings.title"), systemImage: "sidebar.right")
                }
                .help(L("settings.title"))
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.load(url: url)
            }
        }
        .sheet(isPresented: $showExporter) {
            if let loaded {
                ExportDialog(sourceName: loaded.name,
                             result: loaded.result,
                             markers: markers.markers.map { (time: $0.time, label: $0.label) },
                             windowFunction: RenderPreferences.shared.windowFunction.displayName,
                             overlapPercent: RenderPreferences.shared.overlapPercent,
                             onClose: { showExporter = false })
            }
        }
        .fileExporter(isPresented: $showRecordingExporter,
                      document: loaded.flatMap { FLACDocument(sourceURL: $0.url) },
                      contentType: FLACDocument.flacType,
                      defaultFilename: loaded?.name) { _ in }
        .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
            handleDrop(providers)
        }
        .onChange(of: model.openRequested) { _, requested in
            if requested {
                showImporter = true
                model.openRequested = false
            }
        }
        .onChange(of: model.lastURL) { _, newURL in
            // Keyed off `lastURL` (not `loaded?.url`) so it fires only when a
            // genuinely different file is opened — not during a re-analysis,
            // where `state` briefly leaves `.loaded`. That keeps the player,
            // markers, and zoom intact when the user changes channel / FFT /
            // window while a file is playing.
            markers.clear()
            zoom = 1
            if let url = newURL {
                player.load(url: url)
            } else {
                player.unload()
            }
        }
        .onDisappear {
            player.stop()
            recorder.cancel()
        }
    }

    /// Start a microphone recording (also flips the idle source to mic).
    private func startRecording() {
        source = .microphone
        player.stop()
        recorder.start()
    }

    /// Stop recording and open the finished FLAC through the normal load path.
    private func stopRecording() {
        if let url = recorder.stop() {
            model.load(url: url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.isFileURL else { return }
            Task { @MainActor in model.load(url: url) }
        }
        return true
    }
}

// MARK: - States

/// Idle screen: a File / Microphone source toggle over the matching prompt.
private struct IdlePrompt: View {
    @Binding var source: ContentView.Source
    let isTargeted: Bool
    let onOpen: () -> Void
    let onRecord: () -> Void
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(spacing: 24) {
            Picker("", selection: $source) {
                Text(L("source.file")).tag(ContentView.Source.file)
                Text(L("source.microphone")).tag(ContentView.Source.microphone)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)

            switch source {
            case .file:
                DropPrompt(isTargeted: isTargeted, onOpen: onOpen)
            case .microphone:
                RecordPrompt(onRecord: onRecord)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
    }
}

/// Microphone prompt shown on the idle screen when the source is "Microphone".
private struct RecordPrompt: View {
    let onRecord: () -> Void
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "mic.circle")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.secondary)
            Text(L("record.prompt.title"))
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            Text(L("record.prompt.subtitle"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(action: onRecord) {
                Label(L("button.record"), systemImage: "record.circle")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.red)
            Text(L("record.codecNote"))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct DropPrompt: View {
    let isTargeted: Bool
    let onOpen: () -> Void
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.secondary)
            Text(L("prompt.title"))
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            Text(L("prompt.subtitle"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(action: onOpen) {
                Label(L("button.openAudio"), systemImage: "folder")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            Text(L("prompt.formats"))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .padding(16)
            }
        }
        .foregroundStyle(.white)
    }
}

private struct LoadingView: View {
    let name: String
    @ObservedObject private var l10n = LocalizationManager.shared
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(L("status.loading", name))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
    }
}

private struct FailureView: View {
    let message: String
    let onOpen: () -> Void
    @ObservedObject private var l10n = LocalizationManager.shared
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.yellow)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            Button(L("button.chooseAnother"), action: onOpen)
                .buttonStyle(.bordered)
        }
        .padding(40)
        .foregroundStyle(.white)
    }
}

// MARK: - Player bar

private struct PlayerBar: View {
    @ObservedObject var player: AudioPlayerController
    /// Observed so the readout/scrubber follow the live playhead (the controller
    /// itself no longer publishes time).
    @ObservedObject var playhead: PlayheadClock
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!player.isReady)
            .help(player.isPlaying ? L("button.pause") : L("button.play"))

            Text(AxisFormatting.duration(player.currentTime))
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 42, alignment: .trailing)

            Slider(value: sliderBinding, in: 0...maxSlider)
                .tint(.accentColor)
                .disabled(!player.isReady)

            Text(AxisFormatting.duration(player.duration))
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 42, alignment: .leading)

            Button {
                player.toggleMute()
            } label: {
                Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 14))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!player.isReady)
            .help(player.isMuted ? L("button.unmute") : L("button.mute"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var maxSlider: Double { max(player.duration, 0.001) }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { player.currentTime },
            set: { player.seek(to: $0) }
        )
    }
}

// MARK: - File info popover

private struct FileInfoPopover: View {
    let info: AudioFileInfo
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("info.title")).font(.headline)
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                row(L("info.codec"), info.codec)
                row(L("info.sampleRate"), L("unit.khzPlain", info.sampleRate / 1000))
                row(L("info.channels"), channelsText)
                if let bd = info.bitDepth { row(L("info.bitDepth"), L("unit.bitDepth", bd)) }
                if let br = info.bitrate { row(L("info.bitrate"), L("unit.kbps", br / 1000)) }
                row(L("info.duration"), durationText)
                if let size = info.fileSize { row(L("info.fileSize"), sizeText(size)) }
            }
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium).gridColumnAlignment(.leading)
        }
        .font(.system(size: 12))
    }

    private var channelsText: String {
        switch info.channels {
        case 1: return L("info.mono")
        case 2: return L("info.stereo")
        default: return L("unit.channels", info.channels)
        }
    }

    private var durationText: String {
        let total = Int(info.duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Markers popover

private struct MarkersPopover: View {
    @ObservedObject var markers: MarkersStore
    let canAdd: Bool
    let onAdd: () -> Void
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("markers.title")).font(.headline)
                Spacer()
                Button(action: onAdd) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(!canAdd)
                .help(L("button.addMarker"))
            }
            Divider()

            if markers.markers.isEmpty {
                Text(L("markers.empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(markers.markers) { marker in
                            HStack(spacing: 8) {
                                Text(timeLabel(marker.time))
                                    .font(.system(size: 11, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 48, alignment: .leading)
                                TextField(L("marker.placeholder"), text: labelBinding(marker))
                                    .textFieldStyle(.roundedBorder)
                                Button {
                                    markers.remove(marker.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .frame(maxHeight: 240)
                Divider()
                Button(L("markers.clear")) { markers.clear() }
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    private func labelBinding(_ marker: Marker) -> Binding<String> {
        Binding(get: { marker.label },
                set: { markers.updateLabel(marker.id, to: $0) })
    }

    private func timeLabel(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = seconds - Double(m * 60)
        return String(format: "%d:%05.2f", m, s)
    }
}
