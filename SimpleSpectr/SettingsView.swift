//
//  SettingsView.swift
//  SimpleSpectr
//
//  Settings window with an in-app language selector.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        Form {
            Section {
                Picker(L("settings.language"), selection: $l10n.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.menu)

                if l10n.language == .system {
                    Text(L("settings.restartHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 380)
        .navigationTitle(L("settings.title"))
    }
}
