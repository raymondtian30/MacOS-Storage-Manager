import Foundation

/// Finds regenerable junk (caches, build folders, leftovers of uninstalled apps) by measuring known locations directly.
public enum JunkScanner {
    /// Folder names inside ~/Library/Application Support that only hold regenerable cache data.
    static let cacheFolderNames: Set<String> = [
        "Cache", "Caches", "Code Cache", "GPUCache", "CachedData", "CacheStorage", "ShaderCache",
        "GrShaderCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "Crashpad", "CachedExtensionVSIXs"
    ]

    private static let browserMarkers = ["chrome", "safari", "firefox", "mozilla", "edge", "brave", "thebrowser", "opera", "vivaldi"]

    /// Home-relative locations whose *contents* are deleted (the folder itself is kept).
    static let containerRules: [(path: String, kind: CleanupKind, confidence: Int, why: String)] = [
        (".Trash", .trash, 95, "Files already in the Trash still occupy disk space until it is emptied."),
        ("Library/Developer/Xcode/DerivedData", .packageCaches, 95, "Xcode build intermediates; rebuilt on next build."),
        ("Library/Developer/CoreSimulator/Caches", .packageCaches, 90, "Simulator dyld and runtime caches; rebuilt automatically."),
        ("Library/Developer/Xcode/iOS DeviceSupport", .packageCaches, 65, "Debug symbols copied from connected devices; re-copied when a device reconnects."),
        ("Library/Developer/Xcode/watchOS DeviceSupport", .packageCaches, 65, "Debug symbols copied from connected watches; re-copied when needed."),
        ("Library/iTunes/iPhone Software Updates", .iosUpdates, 90, "Downloaded iOS firmware files; Finder re-downloads them if needed."),
        ("Library/iTunes/iPad Software Updates", .iosUpdates, 90, "Downloaded iPadOS firmware files; Finder re-downloads them if needed."),
        (".npm/_cacache", .packageCaches, 85, "npm download cache; packages re-download on demand."),
        ("Library/pnpm/store", .packageCaches, 80, "pnpm content store; re-populated on next install."),
        (".bun/install/cache", .packageCaches, 85, "Bun package cache; re-download on demand."),
        (".cache/uv", .packageCaches, 85, "uv Python package cache; re-download on demand."),
        (".cargo/registry/cache", .packageCaches, 85, "Cargo crate archives; re-download on demand."),
        ("go/pkg/mod/cache", .packageCaches, 80, "Go module download cache; re-download on demand."),
        (".gradle/caches", .packageCaches, 80, "Gradle dependency and build caches; re-download on demand."),
        (".m2/repository", .packageCaches, 60, "Maven local repository; dependencies re-download on next build.")
    ]

    static func containerRoots(home: String) -> Set<String> {
        Set(containerRules.map { "\(home)/\($0.path)" })
    }

    private static let buildFolderManifests: [String: [String]] = [
        "node_modules": ["package.json"],
        ".next": ["package.json"],
        "dist": ["package.json"],
        ".build": ["Package.swift"],
        "target": ["Cargo.toml", "pom.xml"],
        "build": ["build.gradle", "build.gradle.kts", "package.json", "CMakeLists.txt"],
        ".gradle": ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
        "Pods": ["Podfile"],
        ".venv": ["pyproject.toml", "requirements.txt", "setup.py"],
        "venv": ["pyproject.toml", "requirements.txt", "setup.py"],
        "DerivedData": []
    ]

    public static func scan(home: URL, minBytes: Int64 = 5 * 1024 * 1024) -> [CleanupCandidate] {
        let fm = FileManager.default
        let h = home.standardizedFileURL.path
        var out: [CleanupCandidate] = []

        func add(_ path: String, _ kind: CleanupKind, _ confidence: Int, _ why: String, _ consequence: String, lastUsed: Date? = nil) {
            let url = URL(fileURLWithPath: path)
            let size = directorySize(url)
            guard size >= minBytes else { return }
            out.append(CleanupCandidate(
                kind: kind, title: "\(kind.rawValue): \(url.lastPathComponent)",
                whatWillBeRemoved: "Contents of \(url.lastPathComponent)", locationURL: url, sizeBytes: size,
                lastUsedDate: lastUsed, whyRecommended: why, potentialConsequences: consequence, confidence: confidence
            ))
        }

        for rule in containerRules {
            add("\(h)/\(rule.path)", rule.kind, rule.confidence, rule.why, "Removed data is rebuilt or re-downloaded when needed.")
        }

        let installed = installedAppIDs()

        // Every app's folder in ~/Library/Caches, measured separately.
        let caches = "\(h)/Library/Caches"
        for name in (try? fm.contentsOfDirectory(atPath: caches)) ?? [] {
            let path = "\(caches)/\(name)"
            let lower = name.lowercased()
            if isOrphanName(name, installed: installed) {
                add(path, .orphanedAppData, 60, "Cache of an app that is no longer installed.", "None, unless the app is reinstalled.")
            } else if lower == "homebrew" || lower == "yarn" || lower == "pip" || lower == "pypoetry" || lower == "cocoapods" || lower == "org.swift.swiftpm" {
                add(path, .packageCaches, 90, "Package manager download cache; re-downloaded on demand.", "Next install may be slower.")
            } else {
                let isBrowser = browserMarkers.contains { lower.contains($0) }
                add(path, isBrowser ? .browserCaches : .applicationCaches, lower.hasPrefix("com.apple.") ? 70 : 90,
                    "Cache data the app rebuilds automatically.", "The app may load slower once while it rebuilds its cache.")
            }
        }

        // Cache folders nested in ~/Library/Application Support (Chrome, Slack, VS Code, Discord…) and leftovers of removed apps.
        let appSupport = "\(h)/Library/Application Support"
        for name in (try? fm.contentsOfDirectory(atPath: appSupport)) ?? [] where isOrphanName(name, installed: installed) {
            add("\(appSupport)/\(name)", .orphanedAppData, 45, "Support data of an app that is no longer installed.", "Settings and local data for that app are lost if you reinstall it.")
        }
        for path in findDirectories(under: appSupport, maxDepth: 5, seconds: 4, match: { name, _ in cacheFolderNames.contains(name) }) {
            let isBrowser = browserMarkers.contains { path.lowercased().contains($0) }
            add(path, isBrowser ? .browserCaches : .applicationCaches, 85, "Cache data the app rebuilds automatically.", "The app may load slower once while it rebuilds its cache.")
        }
        let savedState = "\(h)/Library/Saved Application State"
        for name in (try? fm.contentsOfDirectory(atPath: savedState)) ?? [] where isOrphanName(name, installed: installed) {
            add("\(savedState)/\(name)", .orphanedAppData, 60, "Window state of an app that is no longer installed.", "None.")
        }

        // Project build folders (node_modules, target, .build…) next to their manifest, scored by how stale the project is.
        let skip: Set<String> = ["Library", ".Trash", ".git", ".cache", ".npm", ".cargo", ".gradle", ".m2", ".bun", "go"]
        let builds = findDirectories(under: h, maxDepth: 7, seconds: 8, skipping: skip) { name, parent in
            guard let manifests = buildFolderManifests[name] else { return false }
            return manifests.isEmpty || manifests.contains { fm.fileExists(atPath: "\(parent)/\($0)") }
        }
        for path in builds {
            let parent = (path as NSString).deletingLastPathComponent
            let modified = (try? fm.attributesOfItem(atPath: parent)[.modificationDate]) as? Date
            let days = Int(Date().timeIntervalSince(modified ?? Date()) / 86_400)
            var confidence = days >= 90 ? 85 : days >= 30 ? 70 : 45
            if path.hasSuffix("venv") { confidence -= 10 }
            add(path, .projectBuildArtifacts, confidence,
                "Generated build output for a project untouched for \(days) days; recreated by its build or install command.",
                "Run the project's install/build command again before using it.", lastUsed: modified)
        }

        return out
    }

    /// Bundle-id-shaped folder name with no installed app from the same vendor.
    public static func isOrphanName(_ name: String, installed: Set<String>) -> Bool {
        let id = name.lowercased().replacingOccurrences(of: ".savedstate", with: "")
        let parts = id.split(separator: ".")
        guard parts.count >= 3, !id.hasPrefix("com.apple."), !id.hasPrefix("group.") else { return false }
        let vendor = parts.prefix(2).joined(separator: ".") + "."
        return !installed.contains { $0 == id || $0.hasPrefix(vendor) || id.hasPrefix($0 + ".") }
    }

    /// True when `path` is a direct child of a Library folder and names an app that is not installed.
    static func isOrphanPath(_ path: String, home: String, installed: Set<String>) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        let roots = ["Library/Application Support", "Library/Caches", "Library/Saved Application State"].map { "\(home)/\($0)" }
        return roots.contains(parent) && isOrphanName((path as NSString).lastPathComponent, installed: installed)
    }

    public static func installedAppIDs() -> Set<String> {
        let roots = ["/Applications", "/System/Applications", "\(NSHomeDirectory())/Applications"]
        var ids: Set<String> = []
        for root in roots {
            let apps = findDirectories(under: root, maxDepth: 3, seconds: 3) { name, _ in name.hasSuffix(".app") }
            for app in apps {
                if let id = Bundle(path: app)?.bundleIdentifier?.lowercased() { ids.insert(id) }
            }
        }
        return ids
    }

    private static func findDirectories(
        under root: String, maxDepth: Int, seconds: TimeInterval, skipping: Set<String> = [],
        match: (String, String) -> Bool
    ) -> [String] {
        guard let e = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants], errorHandler: { _, _ in true }
        ) else { return [] }
        let deadline = Date().addingTimeInterval(seconds)
        var found: [String] = []
        var n = 0
        while let url = e.nextObject() as? URL {
            n += 1
            if n % 256 == 0 && Date() > deadline { break }
            guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  v.isDirectory == true, v.isSymbolicLink != true else { continue }
            let name = url.lastPathComponent
            if match(name, url.deletingLastPathComponent().path) {
                found.append(url.standardizedFileURL.path)
                e.skipDescendants()
            } else if e.level >= maxDepth || skipping.contains(name) {
                e.skipDescendants()
            }
        }
        return found
    }

    static func directorySize(_ url: URL, seconds: TimeInterval = 2) -> Int64 {
        guard let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [], errorHandler: { _, _ in true }
        ) else { return 0 }
        let deadline = Date().addingTimeInterval(seconds)
        var total: Int64 = 0
        var n = 0
        while let f = e.nextObject() as? URL {
            n += 1
            if n % 512 == 0 && Date() > deadline { break }
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}
