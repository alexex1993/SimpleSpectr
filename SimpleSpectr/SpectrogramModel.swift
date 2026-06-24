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

    /// Set to `true` to ask the UI to present the open-file panel (e.g. from the
    /// ⌘O menu command). The view resets it once consumed.
    @Published var openRequested = false

    private var loadToken = 0
    private var loadTask: Task<Void, Never>?
    private var reapplyTask: Task<Void, Never>?
    private var paletteCancellable: AnyCancellable?

    init() {
        // Re-render the loaded spectrogram live when the user picks a palette.
        paletteCancellable = ColormapPreferences.shared.$palette
            .dropFirst()
            .sink { [weak self] palette in self?.reapplyPalette(palette) }
    }

    /// Load and render the spectrogram for `url` off the main thread.
    /// A previous in-flight load is cancelled.
    func load(url: URL) {
        loadTask?.cancel()
        reapplyTask?.cancel()
        let name = url.lastPathComponent
        let palette = ColormapPreferences.shared.palette
        loadToken += 1
        let token = loadToken
        state = .loading(name: name)

        loadTask = Task.detached(priority: .userInitiated) {
            do {
                let result = try SpectrogramEngine.generate(url: url, palette: palette)
                guard !Task.isCancelled else { return }
                await self.finish(token: token, name: name, url: url, result: .success(result))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                await self.finish(token: token, name: name, url: url, result: .failure(error))
            }
        }
    }

    /// Re-render the currently loaded spectrogram with `palette`, reusing the
    /// cached dB grid so the audio is never re-decoded. No-op unless loaded.
    func reapplyPalette(_ palette: Palette) {
        reapplyTask?.cancel()
        guard case .loaded(let name, let url, let result) = state else { return }
        let token = loadToken
        reapplyTask = Task.detached(priority: .userInitiated) {
            do {
                let image = try SpectrogramEngine.renderImage(
                    magnitudes: result.magnitudes,
                    columns: result.columns,
                    bins: result.bins,
                    minDB: Float(result.minDB),
                    maxDB: Float(result.maxDB),
                    palette: palette)
                guard !Task.isCancelled else { return }
                await self.commitReapply(token: token, name: name, url: url, base: result, image: image)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func finish(token: Int, name: String, url: URL, result: Result<SpectrogramResult, Error>) {
        guard token == loadToken else { return } // a newer load superseded this one
        switch result {
        case .success(let res):
            state = .loaded(name: name, url: url, result: res)
        case .failure(let err):
            let message = (err as? LocalizedError)?.errorDescription ?? err.localizedDescription
            state = .failed(message: message)
        }
    }

    private func commitReapply(token: Int, name: String, url: URL, base: SpectrogramResult, image: CGImage) {
        guard token == loadToken else { return }
        state = .loaded(name: name, url: url, result: base.replacingImage(image))
    }
}
