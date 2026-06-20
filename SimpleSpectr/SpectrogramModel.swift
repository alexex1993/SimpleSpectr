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
        case loaded(name: String, result: SpectrogramResult)
        case failed(message: String)
    }

    @Published private(set) var state: State = .idle

    private var loadToken = 0

    /// Load and render the spectrogram for `url` off the main thread.
    func load(url: URL) {
        let name = url.lastPathComponent
        loadToken += 1
        let token = loadToken
        state = .loading(name: name)

        Task.detached(priority: .userInitiated) {
            do {
                let result = try SpectrogramEngine.generate(url: url)
                await self.finish(token: token, name: name, result: .success(result))
            } catch {
                await self.finish(token: token, name: name, result: .failure(error))
            }
        }
    }

    private func finish(token: Int, name: String, result: Result<SpectrogramResult, Error>) {
        guard token == loadToken else { return } // a newer load superseded this one
        switch result {
        case .success(let res):
            state = .loaded(name: name, result: res)
        case .failure(let err):
            let message = (err as? LocalizedError)?.errorDescription ?? err.localizedDescription
            state = .failed(message: message)
        }
    }
}
