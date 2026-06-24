//
//  SettingsView.swift
//  SimpleSpectr
//
//  Settings window with an in-app language selector and colormap picker.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject private var l10n = LocalizationManager.shared
    @ObservedObject private var prefs = ColormapPreferences.shared

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

            Section {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)],
                          spacing: 10) {
                    ForEach(Palette.allCases) { palette in
                        PaletteChip(palette: palette,
                                    isSelected: prefs.palette == palette) {
                            prefs.palette = palette
                        }
                    }
                }
                .padding(.vertical, 2)

                Text(L("settings.paletteHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(L("settings.palette"))
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 420)
        .navigationTitle(L("settings.title"))
    }
}

// MARK: - Palette chip

/// A live, clickable colormap preview: a horizontal gradient sampled from the
/// palette's own LUT, with a selection ring and checkmark on the active one.
private struct PaletteChip: View {
    let palette: Palette
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    LinearGradient(colors: palette.gradientColors(count: 48),
                                   startPoint: .leading,
                                   endPoint: .trailing)
                        .frame(height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                        )

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white, .black.opacity(0.45))
                            .padding(5)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                HStack(spacing: 4) {
                    Text(palette.displayName)
                        .font(.caption)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                    if palette.isDefault {
                        Text(L("palette.default"))
                            .font(.system(size: 8, weight: .medium))
                            .textCase(.uppercase)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.white.opacity(0.05) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.08),
                                  lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .opacity(activeState == .inactive ? 0.6 : 1)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}
