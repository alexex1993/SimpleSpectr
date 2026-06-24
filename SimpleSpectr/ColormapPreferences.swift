//
//  ColormapPreferences.swift
//  SimpleSpectr
//
//  Stores the user's spectrogram colormap choice in UserDefaults.
//

import Foundation
import Combine

/// Tracks the selected spectrogram colormap, persisted across launches.
/// Defaults to `.inferno` (the app's classic palette).
@MainActor
final class ColormapPreferences: ObservableObject {
    static let shared = ColormapPreferences()
    static let storageKey = "spectrogramPalette"

    @Published var palette: Palette {
        didSet { UserDefaults.standard.set(palette.rawValue, forKey: Self.storageKey) }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? Palette.inferno.rawValue
        palette = Palette(rawValue: raw) ?? .inferno
    }
}
