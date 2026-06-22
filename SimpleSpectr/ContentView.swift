//
//  ContentView.swift
//  SimpleSpectr
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: SpectrogramModel
    @State private var showImporter = false
    @State private var isTargetedForDrop = false
    @State private var showExporter = false

    /// The loaded spectrogram (image + suggested file name), if any.
    private var loaded: (name: String, result: SpectrogramResult)? {
        if case .loaded(let name, let result) = model.state { return (name, result) }
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
            case .loaded(let name, let result):
                SpectrogramScene(name: name, result: result)
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
                    Label("Сохранить PNG", systemImage: "square.and.arrow.down")
                }
                .disabled(loaded == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showImporter = true
                } label: {
                    Label("Открыть аудиофайл", systemImage: "waveform")
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
                      document: loaded.map { PNGDocument(image: $0.result.image) },
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

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.secondary)
            Text("Спектрограмма аудио")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Перетащите сюда аудиофайл\nили нажмите кнопку ниже")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(action: onOpen) {
                Label("Открыть аудиофайл", systemImage: "folder")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            Text("FLAC · AAC · MP3 · WAV · AIFF · ALAC и другие")
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
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Анализ \(name)…")
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
    }
}

private struct FailureView: View {
    let message: String
    let onOpen: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.yellow)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            Button("Выбрать другой файл", action: onOpen)
                .buttonStyle(.bordered)
        }
        .padding(40)
        .foregroundStyle(.white)
    }
}
