//
//  Localization.swift
//  SimpleSpectr
//
//  Tracks the user's language preference and exposes the active localized
//  bundle so the UI can switch languages without an app restart.
//

import Foundation
import SwiftUI
import Combine

/// Languages offered in the app's settings.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, ru

    var id: String { rawValue }

    /// Display name in the picker — language autonyms; "system" is localized.
    var displayName: String {
        switch self {
        case .system: return L("lang.system")
        case .en:     return "English"
        case .ru:     return "Русский"
        }
    }
}

/// Tracks the user's language preference and exposes the active localized
/// bundle so the UI can switch languages without an app restart.
@MainActor
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()
    static let storageKey = "appLanguage"

    @Published var language: AppLanguage {
        didSet { apply() }
    }

    /// Bundle for the active language; nil means "use Bundle.main".
    private(set) var bundle: Bundle?

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? AppLanguage.system.rawValue
        language = AppLanguage(rawValue: raw) ?? .system
        apply()
    }

    private func apply() {
        UserDefaults.standard.set(language.rawValue, forKey: Self.storageKey)
        bundle = Self.bundle(for: language)
    }

    private static func bundle(for language: AppLanguage) -> Bundle? {
        let code: String
        switch language {
        case .system:
            // Clear override so future launches use the true system language.
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            code = bestSystemCode()
        case .en, .ru:
            code = language.rawValue
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }
        if let path = Bundle.main.path(forResource: code, ofType: "lproj") {
            return Bundle(path: path)
        }
        return nil
    }

    /// Picks the best supported language from the user's system preferences.
    private static func bestSystemCode() -> String {
        let supported = ["en", "ru"]
        for pref in Locale.preferredLanguages {
            let code = String(pref.prefix(2)).lowercased()
            if supported.contains(code) { return code }
        }
        return "en"
    }
}

/// Looks up a localized string for `key` in the active language bundle.
/// Variadic arguments are substituted via `String(format:)`.
func L(_ key: String, _ args: CVarArg...) -> String {
    let template = (LocalizationManager.shared.bundle ?? .main)
        .localizedString(forKey: key, value: nil, table: "Localizable")
    return args.isEmpty ? template : String(format: template, arguments: args)
}
