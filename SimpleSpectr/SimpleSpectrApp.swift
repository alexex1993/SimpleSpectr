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

    static let repositoryURL = URL(string: "https://github.com/alexex1993/SimpleSpectr")!

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                // Handle files opened from Finder ("Открыть с помощью…").
                .onOpenURL { url in
                    model.load(url: url)
                }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("О программе SimpleSpectr") { showAboutPanel() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Открыть…") {
                    NotificationCenter.default.post(name: .openFileRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Link("Репозиторий на GitHub", destination: Self.repositoryURL)
            }
        }
    }

    /// Standard About panel with a clickable repository link in the credits area.
    private func showAboutPanel() {
        let credits = NSMutableAttributedString(
            string: "Просмотр спектрограмм аудиофайлов.\n\n",
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

extension Notification.Name {
    static let openFileRequested = Notification.Name("SimpleSpectr.openFileRequested")
}
