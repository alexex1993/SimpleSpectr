//
//  AudioPlayerController.swift
//  SimpleSpectr
//
//  Plays back the file shown in the spectrogram and publishes a playhead
//  position so the view can stay in sync with the audio.
//

import Foundation
import AVFoundation
import Combine

/// Playhead position published on its own object so the ~60 fps ticks during
/// playback only invalidate views that actually draw the playhead (spectrogram
/// scene, player bar) — not every view that holds the controller. Previously the
/// controller published `currentTime` directly, so each tick re-rendered
/// `ContentView`, rebuilding its toolbar and tearing down the open view-options
/// menu; its pickers couldn't be used while audio was playing.
@MainActor
final class PlayheadClock: ObservableObject {
    @Published var time: Double = 0
}

@MainActor
final class AudioPlayerController: ObservableObject {

    @Published private(set) var isReady = false
    @Published private(set) var isPlaying = false
    @Published var isMuted = false
    @Published private(set) var duration: Double = 0

    /// The playhead clock. Views that need the live position observe this
    /// directly; the controller itself only publishes low-frequency state.
    let playhead = PlayheadClock()

    /// Current playhead position (seconds), backed by `playhead` so updating it
    /// doesn't fire the controller's own `objectWillChange`.
    var currentTime: Double {
        get { playhead.time }
        set { playhead.time = newValue }
    }

    private var player: AVAudioPlayer?
    private var audioData: Data?
    private var timer: Timer?
    private var volume: Float = 1.0

    /// Load `url` for playback, replacing any previous file.
    func load(url: URL) {
        stop()
        let scoped = url.startAccessingSecurityScopedResource()
        var newPlayer: AVAudioPlayer?
        var newData: Data?
        do {
            let data = try Data(contentsOf: url)
            let p = try AVAudioPlayer(data: data)
            p.volume = isMuted ? 0 : volume
            p.prepareToPlay()
            newPlayer = p
            newData = data
        } catch {
            newPlayer = nil
            newData = nil
        }
        if scoped { url.stopAccessingSecurityScopedResource() }

        player = newPlayer
        audioData = newData
        if let p = newPlayer {
            duration = p.duration
            currentTime = 0
            isReady = true
        } else {
            duration = 0
            currentTime = 0
            isReady = false
        }
    }

    /// Release everything (e.g. when the spectrogram is cleared).
    func unload() {
        stop()
        player = nil
        audioData = nil
        duration = 0
        currentTime = 0
        isReady = false
    }

    func play() {
        guard let p = player, isReady else { return }
        // Restart from the beginning if we are sitting at the very end.
        if duration > 0, currentTime >= duration - 0.01 {
            p.currentTime = 0
            currentTime = 0
        }
        guard p.play() else { return }
        isPlaying = true
        startTimer()
    }

    func pause() {
        guard let p = player else { return }
        p.pause()
        currentTime = p.currentTime
        isPlaying = false
        stopTimer()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        currentTime = 0
        isPlaying = false
        stopTimer()
    }

    /// Seek to an absolute time (seconds), clamped to the file duration.
    func seek(to time: Double) {
        guard let p = player, isReady else { return }
        let t = min(max(time, 0), max(duration, 0))
        p.currentTime = t
        currentTime = t
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        player?.volume = muted ? 0 : volume
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    // MARK: - Playhead ticking

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.005
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let p = player else { return }
        // Natural end of playback: AVAudioPlayer reports isPlaying == false.
        if isPlaying, !p.isPlaying {
            isPlaying = false
            stopTimer()
            currentTime = 0
            p.currentTime = 0
            return
        }
        currentTime = p.currentTime
    }
}
