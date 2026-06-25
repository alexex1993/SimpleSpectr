//
//  RecentFilesStore.swift
//  SimpleSpectr
//
//  Tracks recently opened audio files. Because the app is sandboxed, plain
//  paths cannot be reopened on a later launch — each entry stores a
//  security-scoped bookmark (requires the app-scope bookmark entitlement) so
//  the file can be resolved and re-accessed across launches.
//

import Foundation
import Combine

@MainActor
final class RecentFilesStore: ObservableObject {
    static let shared = RecentFilesStore()
    static let maxItems = 10

    struct Item: Identifiable, Codable {
        var path: String          // last known path, used for display + identity
        var bookmark: Data        // security-scoped bookmark for reopening
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
    }

    @Published private(set) var items: [Item] = []

    private let storageKey = "recentFiles"

    private init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([Item].self, from: data) {
            items = decoded
        }
    }

    /// Record `url` as the most-recent file. Must be called while the URL is
    /// accessible (e.g. just-imported); creates a security-scoped bookmark.
    func add(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else {
            return
        }
        let item = Item(path: url.path, bookmark: bookmark)
        items.removeAll { $0.path == item.path }
        items.insert(item, at: 0)
        if items.count > Self.maxItems { items.removeLast(items.count - Self.maxItems) }
        persist()
    }

    /// Resolve a recent item back to a usable URL. The caller must call
    /// `startAccessingSecurityScopedResource()` before reading (the engine and
    /// player already do). A stale bookmark is refreshed transparently.
    func resolve(_ item: Item) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: item.bookmark,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else {
            return nil
        }
        if stale {
            // Re-create the bookmark while we (briefly) have access.
            let scoped = url.startAccessingSecurityScopedResource()
            if let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                 includingResourceValuesForKeys: nil,
                                                 relativeTo: nil),
               let i = items.firstIndex(where: { $0.id == item.id }) {
                items[i].bookmark = fresh
                persist()
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        return url
    }

    func clear() {
        items.removeAll()
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
