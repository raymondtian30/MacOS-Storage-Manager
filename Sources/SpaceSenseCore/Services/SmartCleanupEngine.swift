import Foundation
import AppKit

public struct SmartCleanupEngine: Sendable {
    private static let protectedPrefixes: [String] = [
        "/System",
        "/usr",
        "/bin",
        "/sbin",
        "/etc",
        "/dev",
        "/Library/Apple",
        "/private/etc",
        "/private/var/db",
        "/private/var/vm"
    ]

    public init() {}

    public static func isProtectedSystemPath(_ path: String, resolveSymlinks: Bool = false) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let exactProtected: Set<String> = [
            "/",
            "/Applications",
            "/Library",
            "/Users",
            "/Volumes",
            "/private",
            "/var",
            "/opt",
            "/cores",
            home,
            "\(home)/Desktop",
            "\(home)/Documents",
            "\(home)/Downloads",
            "\(home)/Library",
            "\(home)/Library/Application Support",
            "\(home)/Library/Keychains",
            "\(home)/Library/Preferences",
            "\(home)/Library/Containers"
        ]

        var candidates = [cleanTrailingSlash(path)]
        if resolveSymlinks {
            let url = URL(fileURLWithPath: path)
            candidates.append(url.standardizedFileURL.path)
            candidates.append(url.resolvingSymlinksInPath().standardizedFileURL.path)
        }

        for candidate in candidates {
            if exactProtected.contains(candidate) {
                return true
            }
            for prefix in protectedPrefixes {
                if candidate == prefix || candidate.hasPrefix(prefix + "/") {
                    return true
                }
            }
            if candidate.hasPrefix("\(home)/Library/Keychains/") ||
               candidate.hasPrefix("\(home)/Library/Containers/") {
                return true
            }
        }
        return false
    }

    private static func cleanTrailingSlash(_ path: String) -> String {
        guard path.count > 1 && path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    /// Runs pure in-memory analysis without synchronous filesystem syscalls so it never blocks the UI.
    public func buildRecommendations(
        scanResult: ScanResult?,
        systemDataReport: SystemDataReport?,
        duplicateGroups: [DuplicateGroup],
        unusedDaysThreshold: Int = 90,
        largeFileThresholdBytes: Int64 = 250 * 1024 * 1024
    ) -> [CleanupCandidate] {
        var candidates: [CleanupCandidate] = []
        var seenPaths: Set<String> = []
        let now = Date()

        // 1. Inspect scanned files for installers, archives, temp files, and unused large files
        if let scanResult {
            for file in scanResult.allFiles {
                let path = file.path
                guard !Self.isProtectedSystemPath(path, resolveSymlinks: false),
                      !seenPaths.contains(path) else {
                    continue
                }

                let ext = file.fileExtension
                let lowerPath = path.lowercased()
                let daysUnused = file.daysSinceLastOpened(from: now)

                // Old Disk Images & Package Installers (.dmg, .pkg, .iso) >= 10 MB
                if ["dmg", "pkg", "iso"].contains(ext), file.size >= 10 * 1024 * 1024 {
                    seenPaths.insert(path)
                    let isInDownloads = lowerPath.contains("/downloads/")
                    candidates.append(
                        CleanupCandidate(
                            kind: .oldInstallers,
                            title: "Installer: \(file.name)",
                            whatWillBeRemoved: "Disk image or installer package '\(file.name)'",
                            locationURL: file.url,
                            sizeBytes: file.size,
                            lastUsedDate: file.lastUsedDate,
                            whyRecommended: "Installer packages and disk images are no longer needed once the app is installed in /Applications.",
                            potentialConsequences: "If you need to reinstall offline later, you would re-download the installer.",
                            risk: isInDownloads ? .low : .moderate,
                            isSelected: isInDownloads
                        )
                    )
                    continue
                }

                // Large temporary / log files (.log, .tmp, .cache) >= 20 MB
                if ["log", "tmp", "temp", "cache"].contains(ext), file.size >= 20 * 1024 * 1024 {
                    seenPaths.insert(path)
                    candidates.append(
                        CleanupCandidate(
                            kind: .largeTempFiles,
                            title: "Log / Temp File: \(file.name)",
                            whatWillBeRemoved: "Temporary or diagnostic log file '\(file.name)'",
                            locationURL: file.url,
                            sizeBytes: file.size,
                            lastUsedDate: file.lastUsedDate,
                            whyRecommended: "Large scratch and log files accumulate over time and are not required for normal app operation.",
                            potentialConsequences: "Past diagnostic log entries in this file will be moved to Trash.",
                            risk: .low,
                            isSelected: true
                        )
                    )
                    continue
                }

                // Old Archives (.zip, .tar.gz, .tgz, .7z, .rar) in Downloads unused for >= 30 days and >= 25 MB
                if ["zip", "gz", "tgz", "7z", "rar", "tar"].contains(ext),
                   lowerPath.contains("/downloads/"),
                   daysUnused >= 30,
                   file.size >= 25 * 1024 * 1024 {
                    seenPaths.insert(path)
                    candidates.append(
                        CleanupCandidate(
                            kind: .oldArchives,
                            title: "Archive: \(file.name)",
                            whatWillBeRemoved: "Compressed archive '\(file.name)' (unused for \(daysUnused) days)",
                            locationURL: file.url,
                            sizeBytes: file.size,
                            lastUsedDate: file.lastUsedDate,
                            whyRecommended: "Compressed archive in Downloads untouched for \(daysUnused) days and likely already extracted.",
                            potentialConsequences: "Verify that extracted contents are saved elsewhere before moving to Trash.",
                            risk: .low,
                            isSelected: false
                        )
                    )
                    continue
                }

                // Large files that haven't been opened or used in >= unusedDaysThreshold days
                let effectiveMinSize = min(largeFileThresholdBytes, 100 * 1024 * 1024)
                if file.size >= effectiveMinSize, daysUnused >= unusedDaysThreshold {
                    seenPaths.insert(path)
                    let isLowRiskLocation = lowerPath.contains("/downloads/") || lowerPath.contains("/movies/")
                    candidates.append(
                        CleanupCandidate(
                            kind: .unusedLargeFiles,
                            title: "Unused (\(daysUnused)d): \(file.name)",
                            whatWillBeRemoved: "Large file '\(file.name)' — not opened or modified for \(daysUnused) days",
                            locationURL: file.url,
                            sizeBytes: file.size,
                            lastUsedDate: file.lastUsedDate,
                            whyRecommended: "Occupies \(ByteFormatting.string(file.size)) and has not been opened or used in \(daysUnused) days (threshold: \(unusedDaysThreshold) days).",
                            potentialConsequences: "Moved to macOS Trash; review if this is an archival media or backup file you still need.",
                            risk: isLowRiskLocation ? .low : .moderate,
                            isSelected: false
                        )
                    )
                }
            }
        }

        // 2. Include safe measured System Data candidates (Xcode DerivedData, User Caches, Logs, Homebrew cache)
        if let systemDataReport {
            for item in systemDataReport.items where item.isUserCleanable && item.recommendation == .recommended {
                guard let url = item.url,
                      let size = item.sizeBytes,
                      size >= 5 * 1024 * 1024,
                      !Self.isProtectedSystemPath(url.path, resolveSymlinks: false),
                      !seenPaths.contains(url.path) else {
                    continue
                }
                seenPaths.insert(url.path)
                let kind: CleanupKind = item.category.contains("Xcode") ? .developerArtifacts : .applicationCaches
                candidates.append(
                    CleanupCandidate(
                        kind: kind,
                        title: item.category,
                        whatWillBeRemoved: "Contents of \(item.category) at \(item.locationPath)",
                        locationURL: url,
                        sizeBytes: size,
                        lastUsedDate: nil,
                        whyRecommended: item.explanation,
                        potentialConsequences: item.potentialRisks,
                        risk: .low,
                        isSelected: false
                    )
                )
            }
        }

        // 3. Include duplicate file copies marked for removal
        for group in duplicateGroups {
            for dup in group.files where dup.isMarkedForRemoval {
                let path = dup.path
                guard !Self.isProtectedSystemPath(path, resolveSymlinks: false),
                      !seenPaths.contains(path) else {
                    continue
                }
                seenPaths.insert(path)
                candidates.append(
                    CleanupCandidate(
                        kind: .duplicateFiles,
                        title: "Duplicate Copy: \(dup.name)",
                        whatWillBeRemoved: "Redundant byte-identical copy '\(dup.name)' (SHA-256 verified)",
                        locationURL: dup.url,
                        sizeBytes: dup.size,
                        lastUsedDate: dup.modificationDate,
                        whyRecommended: "An identical original file with the exact same SHA-256 hash is preserved in another folder.",
                        potentialConsequences: "Only this redundant duplicate is moved to Trash; the original copy remains untouched.",
                        risk: .low,
                        isSelected: true
                    )
                )
            }
        }

        candidates.sort { $0.sizeBytes > $1.sizeBytes }
        return candidates
    }

    /// Safely moves selected URLs to the macOS Trash. Never permanently deletes files.
    public func moveItemsToTrash(urls: [URL], itemSizes: [URL: Int64] = [:]) async -> CleanupExecutionResult {
        var safeURLs: [URL] = []
        var failures: [(path: String, reason: String)] = []

        for url in urls {
            let path = url.standardizedFileURL.path
            if Self.isProtectedSystemPath(path, resolveSymlinks: true) {
                failures.append((path: path, reason: "Protected macOS system path cannot be modified."))
                continue
            }
            if !FileManager.default.fileExists(atPath: path) {
                failures.append((path: path, reason: "File no longer exists at this location."))
                continue
            }
            safeURLs.append(url)
        }

        guard !safeURLs.isEmpty else {
            return CleanupExecutionResult(movedToTrashCount: 0, reclaimedBytes: 0, failures: failures)
        }

        var movedCount = 0
        var reclaimed: Int64 = 0
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let containerRootsToKeepIntact: Set<String> = [
            "\(home)/Library/Caches",
            "\(home)/Library/Logs",
            "\(home)/Library/Developer/Xcode/DerivedData",
            "/private/var/tmp"
        ]

        let sortedSafeURLs = safeURLs.sorted { $0.standardizedFileURL.path.count < $1.standardizedFileURL.path.count }
        var processedParentPaths: [String] = []

        for url in sortedSafeURLs {
            let path = url.standardizedFileURL.path
            if processedParentPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                continue
            }
            processedParentPaths.append(path)

            let size = itemSizes[url] ?? (Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))

            if containerRootsToKeepIntact.contains(path),
               let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                var childMoved = 0
                for child in children {
                    var trashedURL: NSURL?
                    if (try? FileManager.default.trashItem(at: child, resultingItemURL: &trashedURL)) != nil {
                        childMoved += 1
                    }
                }
                if childMoved > 0 || children.isEmpty {
                    movedCount += 1
                    reclaimed += size
                } else {
                    failures.append((path: path, reason: "Could not move contents of '\(url.lastPathComponent)' to Trash."))
                }
                continue
            }

            do {
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
                movedCount += 1
                reclaimed += size
            } catch {
                let recycled = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    NSWorkspace.shared.recycle([url]) { newURLs, recycleError in
                        continuation.resume(returning: recycleError == nil && !newURLs.isEmpty)
                    }
                }
                if recycled {
                    movedCount += 1
                    reclaimed += size
                } else {
                    failures.append((path: path, reason: error.localizedDescription))
                }
            }
        }

        return CleanupExecutionResult(
            movedToTrashCount: movedCount,
            reclaimedBytes: reclaimed,
            failures: failures
        )
    }
}
