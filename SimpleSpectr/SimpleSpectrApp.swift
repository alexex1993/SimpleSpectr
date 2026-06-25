//
//  SimpleSpectrApp.swift
//  SimpleSpectr
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct SimpleSpectrApp: App {
    @StateObject private var model = SpectrogramModel()
    @ObservedObject private var l10n = LocalizationManager.shared
    @ObservedObject private var recents = RecentFilesStore.shared

    static let repositoryURL = URL(string: "https://github.com/alexex1993/SimpleSpectr")!

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                // Handle files opened from Finder ("Open With…").
                .onOpenURL { url in
                    model.load(url: url)
                }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L("menu.about")) { showAboutPanel() }
            }
            CommandGroup(replacing: .newItem) {
                Button(L("menu.open")) {
                    model.openRequested = true
                }
                .keyboardShortcut("o", modifiers: .command)

                Menu(L("menu.recentFiles")) {
                    if recents.items.isEmpty {
                        Button(L("menu.noRecents")) {}.disabled(true)
                    } else {
                        ForEach(recents.items) { item in
                            Button(item.name) { openRecent(item) }
                        }
                        Divider()
                        Button(L("menu.clearRecents")) { recents.clear() }
                    }
                }
            }
            CommandGroup(replacing: .help) {
                Link(L("menu.github"), destination: Self.repositoryURL)
            }
        }
        Settings {
            SettingsView()
        }
    }

    /// Resolve a recent item's security-scoped bookmark and load it.
    private func openRecent(_ item: RecentFilesStore.Item) {
        if let url = recents.resolve(item) {
            model.load(url: url)
        }
    }

    /// Standard About panel with a clickable repository link in the credits area.
    private func showAboutPanel() {
        let credits = NSMutableAttributedString(
            string: L("about.credits"),
            attributes: [.foregroundColor: NSColor.labelColor,
                         .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
        )
        let link = NSAttributedString(
            string: "github.com/alexex1993/SimpleSpectr",
            attributes: [.link: Self.repositoryURL,
                         .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
        )
        credits.append(link)

        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
