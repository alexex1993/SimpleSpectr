//
//  ContentView.swift
//  SimpleSpectr
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: SpectrogramModel
    @ObservedObject private var l10n = LocalizationManager.shared
    @StateObject private var player = AudioPlayerController()
    @State private var showImporter = false
    @State private var isTargetedForDrop = false
    @State private var showExporter = false

    /// The loaded spectrogram (image + source url + suggested file name), if any.
    private var loaded: (name: String, url: URL, result: SpectrogramResult)? {
        if case .loaded(let name, let url, let result) = model.state { return (name, url, result) }
        return nil
    }

    var body: some View {
        ZStack {
            Color(white: 0.07).ignoresSafeArea()

            switch model.state {
            case .idle:
                DropPrompt(isTargeted: isTargetedForDrop) { showImporter = true }
            case .loading(let name):
                LoadingView(name: name)
            case .loaded(let name, let url, let result):
                VStack(spacing: 0) {
                    SpectrogramScene(name: name, result: result, player: player)
                    Divider().overlay(Color.white.opacity(0.08))
                    PlayerBar(player: player)
                }
            case .failed(let message):
                FailureView(message: message) { showImporter = true }
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showExporter = true
                } label: {
                    Label(L("button.savePNG"), systemImage: "square.and.arrow.down")
                }
                .disabled(loaded == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showImporter = true
                } label: {
                    Label(L("button.openAudio"), systemImage: "waveform")
                }
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.load(url: url)
            }
        }
        .fileExporter(isPresented: $showExporter,
                      document: loaded.map {
                          PNGDocument(image: PNGDocument.compositeImage(for: $0.result) ?? $0.result.image)
                      },
                      contentType: .png,
                      defaultFilename: exportFilename) { _ in }
        .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
            handleDrop(providers)
        }
        .onChange(of: model.openRequested) { _, requested in
            if requested {
                showImporter = true
                model.openRequested = false
            }
        }
        .onChange(of: loaded?.url) { _, newURL in
            if let url = newURL {
                player.load(url: url)
            } else {
                player.unload()
            }
        }
        .onDisappear { player.stop() }
    }

    private var exportFilename: String {
        guard let name = loaded?.name else { return "spectrogram" }
        return (name as NSString).deletingPathExtension + "-spectrogram"
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

            Text(formatTime(player.currentTime))
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 42, alignment: .trailing)

            Slider(value: sliderBinding, in: 0...maxSlider)
                .tint(.accentColor)
                .disabled(!player.isReady)

            Text(formatTime(player.duration))
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

    private func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
