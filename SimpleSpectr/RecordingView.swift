//
//  RecordingView.swift
//  SimpleSpectr
//
//  Full-screen UI shown while recording from the microphone: a live spectrogram
//  that grows left→right plus a Stop control. Mic-permission-denied and failure
//  states are handled here too. Full axes / hover / playback come after Stop,
//  when the finished file is reopened through the normal `SpectrogramModel` path.
//

import SwiftUI
import UniformTypeIdentifiers

struct RecordingView: View {
    @ObservedObject var recorder: AudioRecorderController
    let onStop: () -> Void
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        switch recorder.phase {
        case .recording:
            recordingBody
        case .denied:
            messageBody(icon: "mic.slash",
                        tint: .yellow,
                        title: L("record.permissionDenied"),
                        showSettings: true)
        case .failed(let message):
            messageBody(icon: "exclamationmark.triangle",
                        tint: .yellow,
                        title: message,
                        showSettings: false)
        case .idle:
            Color.clear
        }
    }

    // MARK: - Recording

    private var recordingBody: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let image = recorder.liveImage {
                    // Low freq at bottom (CGImage has high freq at row 0), time L→R.
                    Image(decorative: image, scale: 1.0)
                        .resizable()
                        .interpolation(.medium)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text(L("record.waiting"))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(Color.white.opacity(0.08))
            controlBar
        }
    }

    private var controlBar: some View {
        HStack(spacing: 14) {
            // Pulsing red indicator + elapsed time.
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .opacity(blinkOn ? 1 : 0.25)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: blinkOn)
                .onAppear { blinkOn = true }
            Text(L("record.recording"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Text(AxisFormatting.duration(recorder.elapsed))
                .font(.system(size: 12, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer()

            Text(L("record.codecNote"))
                .font(.footnote)
                .foregroundStyle(.tertiary)

            Button(action: onStop) {
                Label(L("button.stopRecording"), systemImage: "stop.fill")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @State private var blinkOn = false

    // MARK: - Denied / failed

    private func messageBody(icon: String, tint: Color, title: String, showSettings: Bool) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(tint)
            Text(title)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            if showSettings {
                Button(L("button.openSettings")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            Button(L("button.chooseAnother")) { recorder.reset() }
                .buttonStyle(.bordered)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
    }
}

// MARK: - FLAC export document

/// Wraps a recorded FLAC file's bytes as a `FileDocument` so "Save recording"
/// can copy it out of the sandbox container via `.fileExporter`.
struct FLACDocument: FileDocument {
    static let flacType = UTType(filenameExtension: "flac") ?? .audio
    static var readableContentTypes: [UTType] { [flacType] }
    static var writableContentTypes: [UTType] { [flacType] }

    let data: Data

    init?(sourceURL: URL) {
        guard let data = try? Data(contentsOf: sourceURL) else { return nil }
        self.data = data
    }

    // Required by FileDocument; this document is export-only.
    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
