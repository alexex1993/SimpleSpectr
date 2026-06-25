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
    case system
    case en, ru
    case zhHans = "zh-Hans"
    case es, de, fr, hi, it, ja
    case ptBR = "pt-BR"
    case ar, bn, tr, ko

    var id: String { rawValue }

    /// Display name in the picker — language autonyms; "system" is localized.
    var displayName: String {
        switch self {
        case .system: return L("lang.system")
        case .en:     return "English"
        case .ru:     return "Русский"
        case .zhHans: return "中文"
        case .es:     return "Español"
        case .de:     return "Deutsch"
        case .fr:     return "Français"
        case .hi:     return "हिन्दी"
        case .it:     return "Italiano"
        case .ja:     return "日本語"
        case .ptBR:   return "Português"
        case .ar:     return "العربية"
        case .bn:     return "বাংলা"
        case .tr:     return "Türkçe"
        case .ko:     return "한국어"
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

    /// English bundle, used as a fallback when a key is missing from the active
    /// language so new strings never surface as raw `dotted.identifiers`.
    static let enFallbackBundle: Bundle? = {
        Bundle.main.path(forResource: "en", ofType: "lproj").flatMap { Bundle(path: $0) }
    }()

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
            // Don't override AppleLanguages — let the OS's real preferences
            // stand (so unsupported system locales keep native date/number
            // formatting). We only resolve *which* of our bundles to load.
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            code = bestSystemCode()
        default:
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
        let supported = AppLanguage.allCases.filter { $0 != .system }.map { $0.rawValue }
        for pref in Locale.preferredLanguages {
            let lower = pref.lowercased()
            // Exact match first (e.g. "zh-hans", "pt-br").
            if supported.contains(lower) { return lower }
            // Map script/region variants onto our base codes
            // (e.g. "zh-hant-tw" -> "zh-Hans", "pt-pt" -> "pt-BR").
            let primary = String(pref.prefix { $0 != "-" && $0 != "_" }).lowercased()
            if let match = Self.code(forPrimary: primary, in: supported) {
                return match
            }
        }
        return "en"
    }

    /// Resolves a primary language subtag (e.g. "zh", "pt", "es") to a
    /// supported bundle code, collapsing regional/script variants onto the
    /// single variant we ship.
    private static func code(forPrimary primary: String, in supported: [String]) -> String? {
        switch primary {
        case "zh": return "zh-Hans"
        case "pt": return "pt-BR"
        default:   return supported.first { $0.lowercased() == primary }
        }
    }
}

/// Looks up a localized string for `key` in the active language bundle.
/// Variadic arguments are substituted via `String(format:)`.
func L(_ key: String, _ args: CVarArg...) -> String {
    let sentinel = "\u{0}missing\u{0}"
    var template = (LocalizationManager.shared.bundle ?? .main)
        .localizedString(forKey: key, value: sentinel, table: "Localizable")
    if template == sentinel {
        // Missing in the active language — fall back to English, then the key.
        template = (LocalizationManager.enFallbackBundle ?? .main)
            .localizedString(forKey: key, value: key, table: "Localizable")
    }
    return args.isEmpty ? template : String(format: template, arguments: args)
}
