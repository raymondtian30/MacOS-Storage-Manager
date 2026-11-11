import Foundation
import AppKit

public final class BookmarkManager: @unchecked Sendable {
    private let defaultsKey = "com.spacesense.securityScopedBookmarks"
    private let lock = NSLock()
    private var activeURLs: [String: URL] = [:]

    public init() {}

    public func saveBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var existing = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
            existing[url.path] = data
            UserDefaults.standard.set(existing, forKey: defaultsKey)
        } catch {
            // Non-sandboxed CLI or standard directory access may not require security scope; ignore gracefully
        }
    }

    public func restoreSavedBookmarks() -> [URL] {
        guard let saved = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] else {
            return []
        }
        var restored: [URL] = []
        for (_, data) in saved {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                if url.startAccessingSecurityScopedResource() {
                    lock.lock()
                    activeURLs[url.path] = url
                    lock.unlock()
                }
                restored.append(url)
            }
        }
        return restored
    }

    public func startAccessing(_ url: URL) -> Bool {
        let accessed = url.startAccessingSecurityScopedResource()
        if accessed {
            lock.lock()
            activeURLs[url.path] = url
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
        panel.title = "Choose a Folder or Volume to Analyze"
        panel.message = "SpaceSense will analyze file and folder sizes locally on your Mac."
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
