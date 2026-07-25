//
//  VideoExportDialog.swift
//  SimpleSpectr
//
//  Sheet that configures and drives the "3D flyover" video export
//  (SpectrogramVideoExport.swift): pick an aspect ratio, resolution, frame rate
//  and a bit of camera drama, choose where to save, then watch the progress bar.
//

import SwiftUI
import AppKit
import Combine
import AVFoundation
import UniformTypeIdentifiers

/// Thread-safe cancel flag shared with the detached export task.
nonisolated final class ExportCancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return _cancelled
    }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
}

/// Drives one export: owns the options, progress and the running task.
@MainActor
final class VideoExportController: ObservableObject {
    enum Phase: Equatable {
        case configuring
        case exporting(Double)   // 0…1
        case finished(URL)
        case failed(String)
    }

    @Published var options = VideoExportOptions()
    @Published private(set) var phase: Phase = .configuring

    private var task: Task<Void, Never>?
    private var token: ExportCancelToken?

    var isExporting: Bool { if case .exporting = phase { return true }; return false }

    func start(result: SpectrogramResult, palette: Palette, sourceURL: URL, outputURL: URL) {
        let snapshot = VideoGridSnapshot(result: result, palette: palette)
        let opts = options
        let token = ExportCancelToken()
        self.token = token
        phase = .exporting(0)

        task = Task.detached(priority: .userInitiated) { [weak self] in
            let progress: @Sendable (Double) -> Void = { p in
                Task { @MainActor [weak self] in
                    guard let self, self.isExporting else { return }
                    self.phase = .exporting(min(max(p, 0), 1))
                }
            }
            do {
                try await SpectrogramVideoExporter.export(
                    snapshot: snapshot,
                    options: opts,
                    sourceURL: sourceURL,
                    outputURL: outputURL,
                    progress: progress,
                    isCancelled: { token.isCancelled })
                await MainActor.run { self?.phase = .finished(outputURL) }
            } catch is CancellationError {
                await MainActor.run { self?.phase = .configuring }
            } catch VideoExportError.cancelled {
                await MainActor.run { self?.phase = .configuring }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { self?.phase = .failed(message) }
            }
        }
    }

    func cancel() {
        token?.cancel()
        task?.cancel()
    }
}

struct VideoExportDialog: View {
    let sourceName: String
    let sourceURL: URL
    let result: SpectrogramResult
    let palette: Palette
    let onClose: () -> Void

    @ObservedObject private var l10n = LocalizationManager.shared
    @StateObject private var controller = VideoExportController()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("video.title"))
                .font(.headline)
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 4)
            Text(L("video.subtitle"))
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.bottom, 12)

            Form {
                formatSection
                cameraSection
                backgroundSection
                estimateSection
            }
            .formStyle(.grouped)
            .frame(height: 380)
            .disabled(controller.isExporting)

            Divider()
            footer
        }
        .frame(width: 480)
    }

    // MARK: Sections

    private var formatSection: some View {
        Section(L("video.section.format")) {
            Picker(L("video.aspect"), selection: $controller.options.aspect) {
                ForEach(VideoAspect.allCases) { a in Text(a.displayName).tag(a) }
            }
            Picker(L("video.quality"), selection: $controller.options.quality) {
                ForEach(VideoQuality.allCases) { q in Text(q.displayName).tag(q) }
            }
            Picker(L("video.fps"), selection: $controller.options.fps) {
                Text("30").tag(Int32(30))
                Text("60").tag(Int32(60))
            }
            .pickerStyle(.segmented)
        }
    }

    private var cameraSection: some View {
        Section(L("video.section.camera")) {
            slider(L("video.height"), value: $controller.options.heightExaggeration, range: 0.4...2.0)
            slider(L("video.tilt"), value: $controller.options.cameraTilt, range: 0...1)
            slider(L("video.sway"), value: $controller.options.sway, range: 0...1)
        }
    }

    private var backgroundSection: some View {
        // A titled section with a footer needs the header/footer form — there is
        // no `Section(_ title:) { } footer: { }` overload.
        Section {
            Toggle(L("video.stars"), isOn: $controller.options.showStars)
            Toggle(L("video.grid"), isOn: $controller.options.showGrid)
            Toggle(L("video.pulse"), isOn: $controller.options.pulseWithAudio)
        } header: {
            Text(L("video.section.background"))
        } footer: {
            Text(L("video.backgroundHint")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var estimateSection: some View {
        Section {
            LabeledContent(L("video.resolution"), value: resolutionText)
            LabeledContent(L("video.codec"), value: controller.options.codec == .hevc ? "HEVC" : "H.264")
            LabeledContent(L("video.duration"), value: durationText)
        } footer: {
            Text(L("video.hint")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            switch controller.phase {
            case .exporting(let p):
                ProgressView(value: p)
                    .frame(width: 160)
                Text("\(Int(p * 100))%").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button(L("export.cancel"), role: .cancel) { controller.cancel() }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).lineLimit(2)
                Spacer()
                Button(L("export.cancel"), role: .cancel) { onClose() }
                Button(L("video.export")) { chooseAndExport() }.buttonStyle(.borderedProminent)
            case .finished(let url):
                Label(L("video.done"), systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
                Spacer()
                Button(L("video.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button(L("video.close")) { onClose() }.buttonStyle(.borderedProminent)
            case .configuring:
                Spacer()
                Button(L("export.cancel"), role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button(L("video.export")) { chooseAndExport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: Helpers

    private func slider(_ label: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        HStack {
            Text(label).frame(width: 130, alignment: .leading)
            Slider(value: Binding(get: { Double(value.wrappedValue) },
                                  set: { value.wrappedValue = Float($0) }),
                   in: Double(range.lowerBound)...Double(range.upperBound))
        }
    }

    private var resolutionText: String {
        let (w, h) = controller.options.pixelSize
        return "\(w) × \(h)"
    }

    private var durationText: String {
        let s = Int(result.duration.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var defaultFilename: String {
        let base = (sourceName as NSString).deletingPathExtension
        let stem = base.isEmpty ? "spectrogram" : base
        return stem + "-flyover.mp4"
    }

    private func chooseAndExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = defaultFilename
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            controller.start(result: result, palette: palette, sourceURL: sourceURL, outputURL: url)
        }
    }
}
