import Foundation
import AppKit

public final class BookmarkManager: @unchecked Sendable {
    private let defaultsKey = "com.spacesense.securityScopedBookmarks"
    private let lock = NSLock()
    private var activeURLs: [String: URL] = [:]

    public init() {}

    public func saveBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        var existing = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
        existing[url.standardizedFileURL.path] = data
        UserDefaults.standard.set(existing, forKey: defaultsKey)
    }

    public func restoreSavedBookmarks() -> [URL] {
        lock.lock()
        let saved = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
        lock.unlock()
        guard !saved.isEmpty else { return [] }

        var restored: [URL] = []
        var staleURLsToRefresh: [URL] = []

        for (_, data) in saved {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                _ = startAccessing(url)
                if isStale {
                    staleURLsToRefresh.append(url)
                }
                restored.append(url)
            }
        }

        for staleURL in staleURLsToRefresh {
            saveBookmark(for: staleURL)
        }
        return restored
    }

    public func startAccessing(_ url: URL) -> Bool {
        let key = url.standardizedFileURL.path
        lock.lock()
        if activeURLs[key] != nil {
            lock.unlock()
            return true
        }
        lock.unlock()

        let accessed = url.startAccessingSecurityScopedResource()
        if accessed {
            lock.lock()
            activeURLs[key] = url
            lock.unlock()
        }
        return accessed
    }

    public func stopAccessingAll() {
        lock.lock()
        let urls = Array(activeURLs.values)
        activeURLs.removeAll()
        lock.unlock()
        for url in urls {
            url.stopAccessingSecurityScopedResource()
        }
    }

    @MainActor
    public func promptForDirectory(initialURL: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder or Volume"
        panel.message = "SpaceSense analyzes file and folder sizes locally on your Mac."
        panel.prompt = "Select Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if let initialURL {
            panel.directoryURL = initialURL
        }
        let response = panel.runModal()
        guard response == .OK, let selectedURL = panel.url else {
            return nil
        }
        _ = startAccessing(selectedURL)
        saveBookmark(for: selectedURL)
        return selectedURL
    }
}
