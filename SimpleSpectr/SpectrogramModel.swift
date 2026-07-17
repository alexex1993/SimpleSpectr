//
//  SpectrogramModel.swift
//  SimpleSpectr
//
//  Observable state driving the UI: loads a file and computes its spectrogram.
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class SpectrogramModel: ObservableObject {

    enum State {
        case idle
        case loading(name: String)
        case loaded(name: String, url: URL, result: SpectrogramResult)
        case failed(message: String)
    }

    @Published private(set) var state: State = .idle

    /// Container metadata (codec, sample rate, bitrate…) for the loaded file,
    /// shown in the "File Info" popover. `nil` until a file finishes loading.
    @Published private(set) var fileInfo: AudioFileInfo?

    /// Set to `true` to ask the UI to present the open-file panel (e.g. from the
    /// ⌘O menu command). The view resets it once consumed.
    @Published var openRequested = false

    private var loadToken = 0
    private var loadTask: Task<Void, Never>?
    private var reapplyTask: Task<Void, Never>?
    private var displayCancellable: AnyCancellable?
    private var analysisCancellables: Set<AnyCancellable> = []

    /// URL of the file currently being analyzed (or last analyzed), tracked
    /// independently of `state` so a settings change can trigger a reload even
    /// while a load is in flight (state == .loading).
    private var lastURL: URL?

    /// Set when a display setting (palette / scale) changes during a load; the
    /// in-flight `generate` already captured the old display values, so once it
    /// lands we re-render from cache to honor the change.
    private var needsDisplayRefresh = false

    init() {
        setupReactiveBindings()
    }

    /// Re-render live when display-only settings change (palette, frequency
    /// scale — both reuse the cached dB grid); re-decode when analysis settings
    /// change (FFT size, overlap, window — they alter the STFT itself).
    ///
    /// `@Published` emits from `willSet`, *before* the value is stored, so a
    /// synchronous re-read in the sink would observe the stale (pre-change)
    /// value. `.receive(on: RunLoop.main)` defers the sink to the next runloop
    /// turn — by then `didSet` has run and the stored value is current.
    private func setupReactiveBindings() {
        // Display: palette, frequency scale, and the dB color window / reference
        // level → cheap re-render from the cached grid (no audio re-decode).
        let render = RenderPreferences.shared
        let levels = Publishers.CombineLatest3(
            render.$dbFloor, render.$dbCeiling, render.$referenceLevel
        ).map { _, _, _ in () }
        displayCancellable = Publishers.CombineLatest3(
            ColormapPreferences.shared.$palette.map { _ in () },
            render.$frequencyScale.map { _ in () },
            levels
        )
        .dropFirst()
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _, _ in self?.rerenderFromCache() }

        // Analysis: FFT size / overlap / window → full re-decode of current file.
        RenderPreferences.shared.$fftSize
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reloadCurrent() }
            .store(in: &analysisCancellables)
        RenderPreferences.shared.$overlapPercent
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reloadCurrent() }
            .store(in: &analysisCancellables)
        RenderPreferences.shared.$windowFunction
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reloadCurrent() }
            .store(in: &analysisCancellables)
    }

    /// Load and render the spectrogram for `url` off the main thread.
    /// A previous in-flight load is cancelled.
    func load(url: URL) {
        lastURL = url
        loadTask?.cancel()
        reapplyTask?.cancel()
        needsDisplayRefresh = false
        fileInfo = nil
        RecentFilesStore.shared.add(url: url)
        let name = url.lastPathComponent
        let palette = ColormapPreferences.shared.palette
        let render = RenderPreferences.shared
        // Snapshot the MainActor-isolated settings before leaving the actor.
        let fftSize = render.fftSize
        let overlapPercent = render.overlapPercent
        let windowFunction = render.windowFunction
        let frequencyScale = render.frequencyScale
        let window = render.colorWindow
        loadToken += 1
        let token = loadToken
        state = .loading(name: name)

        loadTask = Task.detached(priority: .userInitiated) {
            do {
                let result = try SpectrogramEngine.generate(
                    url: url,
                    fftSize: fftSize,
                    overlapPercent: overlapPercent,
                    windowFunction: windowFunction,
                    frequencyScale: frequencyScale,
                    palette: palette,
                    minDB: window.min,
                    maxDB: window.max)
                guard !Task.isCancelled else { return }
                let info = AudioFileInfo.load(url: url)
                await self.finish(token: token, name: name, url: url, info: info, result: .success(result))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                await self.finish(token: token, name: name, url: url, info: nil, result: .failure(error))
            }
        }
    }

    /// Re-analyze the currently loaded file with the latest settings.
    /// Uses `lastURL` so it works even mid-load (the in-flight load is cancelled).
    func reloadCurrent() {
        guard let url = lastURL else { return }
        load(url: url)
    }

    /// Re-render the currently loaded spectrogram from its cached dB grid using
    /// the current palette and frequency scale. If a load is in flight, defer
    /// the refresh — `generate` captured the old display values, so we re-render
    /// once it lands (see `finish`).
    func rerenderFromCache() {
        reapplyTask?.cancel()
        guard case .loaded(let name, let url, let result) = state else {
            if case .loading = state { needsDisplayRefresh = true }
            return
        }
        let palette = ColormapPreferences.shared.palette
        let scale = RenderPreferences.shared.frequencyScale
        let window = RenderPreferences.shared.colorWindow
        let token = loadToken
        let axis = FrequencyAxis.make(scale: scale,
                                      sampleRate: result.sampleRate,
                                      fftSize: result.fftSize,
                                      bins: result.bins)
        reapplyTask = Task.detached(priority: .userInitiated) {
            do {
                let image = try SpectrogramEngine.renderImage(
                    magnitudes: result.magnitudes,
                    columns: result.columns,
                    bins: result.bins,
                    minDB: window.min,
                    maxDB: window.max,
                    palette: palette,
                    frequencyAxis: axis)
                guard !Task.isCancelled else { return }
                await self.commitRerender(token: token,
                                          name: name,
                                          url: url,
                                          base: result,
                                          image: image,
                                          scale: scale,
                                          minFrequency: axis.minFrequency,
                                          minDB: Double(window.min),
                                          maxDB: Double(window.max))
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func finish(token: Int, name: String, url: URL, info: AudioFileInfo?, result: Result<SpectrogramResult, Error>) {
        guard token == loadToken else { return } // a newer load superseded this one
        switch result {
        case .success(let res):
            fileInfo = info
            state = .loaded(name: name, url: url, result: res)
            // A display setting changed while this load was running (palette /
            // scale); generate used the old values, so re-render from the cache.
            if needsDisplayRefresh {
                needsDisplayRefresh = false
                rerenderFromCache()
            }
        case .failure(let err):
            let message = (err as? LocalizedError)?.errorDescription ?? err.localizedDescription
            state = .failed(message: message)
        }
    }

    private func commitRerender(token: Int,
                                name: String,
                                url: URL,
                                base: SpectrogramResult,
                                image: CGImage,
                                scale: FrequencyScale,
                                minFrequency: Double,
                                minDB: Double,
                                maxDB: Double) {
        guard token == loadToken else { return }
        state = .loaded(name: name, url: url,
                        result: base.rerendered(image: image,
                                                scale: scale,
                                                minDisplayedFrequency: minFrequency,
                                                minDB: minDB,
                                                maxDB: maxDB))
    }
}
