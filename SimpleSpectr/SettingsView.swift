//
//  SettingsView.swift
//  SimpleSpectr
//
//  Settings form (language, analysis, render, palette) hosted in the main
//  window's trailing `.inspector` panel. Sizing/chrome is owned by the host
//  (ContentView) so this view stays layout-agnostic.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject private var l10n = LocalizationManager.shared
    @ObservedObject private var prefs = ColormapPreferences.shared
    @ObservedObject private var render = RenderPreferences.shared

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
                Picker(L("settings.fftSize"), selection: $render.fftSize) {
                    ForEach(RenderPreferences.fftSizeOptions, id: \.self) { size in
                        Text(formattedFFT(size)).tag(size)
                    }
                }
                .pickerStyle(.menu)

                Picker(L("settings.overlap"), selection: $render.overlapPercent) {
                    ForEach(RenderPreferences.overlapOptions, id: \.self) { pct in
                        Text(formattedOverlap(pct)).tag(pct)
                    }
                }
                .pickerStyle(.menu)

                Picker(L("settings.window"), selection: $render.windowFunction) {
                    ForEach(WindowFunction.allCases) { w in
                        Text(w.displayName).tag(w)
                    }
                }
                .pickerStyle(.menu)

                Text(render.windowFunction.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(L("settings.channel"), selection: $render.channelMode) {
                    ForEach(ChannelMode.allCases) { c in
                        Text(c.displayName).tag(c)
                    }
                }
                .pickerStyle(.menu)

                Text(L("settings.channelHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(L("settings.analysisHint"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Text(L("settings.analysis"))
            }

            Section {
                Picker(L("settings.scale"), selection: $render.frequencyScale) {
                    ForEach(FrequencyScale.allCases) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                .pickerStyle(.menu)

                Text(L("settings.scaleHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(L("settings.magnitude"), selection: $render.magnitudeScale) {
                    ForEach(MagnitudeScale.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.segmented)

                Text(L("settings.magnitudeHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(L("settings.freqAxis"))
            }

            Section {
                levelSlider(L("settings.dbCeiling"),
                            value: $render.dbCeiling,
                            range: RenderPreferences.dbCeilingRange)
                levelSlider(L("settings.dbFloor"),
                            value: $render.dbFloor,
                            range: RenderPreferences.dbFloorRange)
                levelSlider(L("settings.referenceLevel"),
                            value: $render.referenceLevel,
                            range: RenderPreferences.referenceLevelRange)

                Text(L("settings.levelsHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(L("settings.resetLevels")) { render.resetLevels() }
                    .controlSize(.small)
            } header: {
                Text(L("settings.levels"))
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
    }

    /// A labeled dB slider with a live numeric readout on the right.
    @ViewBuilder
    private func levelSlider(_ title: String,
                             value: Binding<Double>,
                             range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%+.0f dB", value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: 1)
        }
    }

    /// "2048" or "2048 — Default" for the factory default size.
    private func formattedFFT(_ size: Int) -> String {
        size == RenderPreferences.defaultFFTSize
            ? "\(size) — \(L("palette.default"))"
            : "\(size)"
    }

    /// "75%" with the default badge on the factory choice.
    private func formattedOverlap(_ pct: Double) -> String {
        let suffix = pct == RenderPreferences.defaultOverlap
            ? " — \(L("palette.default"))"
            : ""
        // Drop a redundant ".0" so 75 shows as "75%" not "75.0%".
        let value = pct.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", pct)
            : String(format: "%.1f", pct)
        return "\(value)%\(suffix)"
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
