//
//  AudioRecorderController.swift
//  SimpleSpectr
//
//  Records microphone audio to a lossless FLAC file while driving a live
//  spectrogram preview. An AVAudioEngine input tap (audio thread) writes each
//  buffer to the file and pushes mono samples into a `LiveSpectrogram`; a main
//  run-loop timer pulls a preview image and the elapsed time for the UI.
//

import Foundation
import AVFoundation
import Accelerate
import Combine
import CoreGraphics

@MainActor
final class AudioRecorderController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case recording
        case denied
        case failed(message: String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var liveImage: CGImage?
    @Published private(set) var level: Float = 0   // 0…1 input meter

    /// Cap on the live preview width (output columns); keeps rebuild cost bounded.
    private static let previewMaxWidth = 1600

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var live: LiveSpectrogram?
    private var recordingURL: URL?
    private var timer: Timer?
    private var startDate: Date?

    private let palette: Palette
    private let scale: FrequencyScale

    init() {
        palette = ColormapPreferences.shared.palette
        scale = RenderPreferences.shared.frequencyScale
    }

    var isRecording: Bool { phase == .recording }

    /// Request mic access (if needed) and begin recording.
    func start() {
        guard phase != .recording else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if granted { self.beginRecording() } else { self.phase = .denied }
                }
            }
        default:
            phase = .denied
        }
    }

    private func beginRecording() {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            phase = .failed(message: L("record.error.noInput"))
            return
        }

        let url: URL
        do {
            url = try Self.makeRecordingURL()
        } catch {
            phase = .failed(message: error.localizedDescription)
            return
        }

        // FLAC at the input's native rate / channel count → the file's
        // processingFormat matches the tap buffer, so writes need no conversion.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount
        ]

        let newFile: AVAudioFile
        do {
            newFile = try AVAudioFile(forWriting: url, settings: settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            phase = .failed(message: error.localizedDescription)
            return
        }

        let render = RenderPreferences.shared
        let liveSpectro = LiveSpectrogram(fftSize: render.fftSize,
                                          overlapPercent: render.overlapPercent,
                                          windowFunction: render.windowFunction,
                                          sampleRate: format.sampleRate,
                                          maxWidth: Self.previewMaxWidth)

        let channelCount = Int(format.channelCount)
        // Audio-thread tap: write to file + feed the live STFT. Captures only
        // Sendable / off-main objects — never touches this @MainActor controller.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            try? newFile.write(from: buffer)
            guard let mono = Self.downmix(buffer, channelCount: channelCount) else { return }
            liveSpectro.append(mono)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            liveSpectro.finish()
            phase = .failed(message: error.localizedDescription)
            return
        }

        file = newFile
        live = liveSpectro
        recordingURL = url
        startDate = Date()
        elapsed = 0
        liveImage = nil
        level = 0
        phase = .recording
        startTimer()
    }

    /// Stop recording, finalize the FLAC file, and return its URL (nil on failure).
    @discardableResult
    func stop() -> URL? {
        guard phase == .recording else { return nil }
        stopTimer()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        live?.finish()
        live = nil
        // Releasing the AVAudioFile flushes and closes it.
        file = nil
        let url = recordingURL
        recordingURL = nil
        startDate = nil
        phase = .idle
        liveImage = nil
        level = 0
        return url
    }

    /// Stop and discard the in-progress recording file.
    func cancel() {
        if let url = stop() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Clear a non-recording error/denied state back to idle.
    func reset() {
        if phase != .recording { phase = .idle }
    }

    // MARK: - Live preview ticking

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        if let startDate { elapsed = Date().timeIntervalSince(startDate) }
        if let live {
            let window = RenderPreferences.shared.colorWindow
            liveImage = live.snapshotImage(palette: palette, scale: scale,
                                           minDB: window.min, maxDB: window.max)
        }
    }

    // MARK: - Helpers

    /// Down-mix an interleaved/deinterleaved float buffer to a mono `[Float]`.
    private nonisolated static func downmix(_ buffer: AVAudioPCMBuffer, channelCount: Int) -> [Float]? {
        guard let channels = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: frames))
        }
        var mono = [Float](repeating: 0, count: frames)
        for ch in 0..<channelCount {
            vDSP_vadd(mono, 1, channels[ch], 1, &mono, 1, vDSP_Length(frames))
        }
        var inv = 1.0 / Float(channelCount)
        vDSP_vsmul(mono, 1, &inv, &mono, 1, vDSP_Length(frames))
        return mono
    }

    /// A persistent, timestamped FLAC URL in the app's Recordings folder, so the
    /// recording survives long enough for Recent Files / reload; "Save" copies it out.
    private static func makeRecordingURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("SimpleSpectr/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Brand prefix (not localized) + timestamp, e.g.
        // "SimpleSpectr 2026-06-27 09.15.30.flac". This becomes the default name in
        // the "Save recording" panel too (the exporter defaults to the file's name).
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "SimpleSpectr \(formatter.string(from: Date())).flac"
        return dir.appendingPathComponent(name)
    }

    /// Whether `url` points inside the app's Recordings folder (drives the
    /// "Save recording" affordance for freshly captured takes).
    static func isRecordingURL(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent == "Recordings"
            && url.pathExtension.lowercased() == "flac"
    }
}
