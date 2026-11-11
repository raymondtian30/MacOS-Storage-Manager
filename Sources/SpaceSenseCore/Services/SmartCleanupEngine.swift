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

    public static func isProtectedSystemPath(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let standardized = url.standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

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

        for candidate in [standardized, resolved] {
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

    public func buildRecommendations(
        scanResult: ScanResult?,
        systemDataReport: SystemDataReport?,
        duplicateGroups: [DuplicateGroup]
    ) -> [CleanupCandidate] {
        var candidates: [CleanupCandidate] = []
        var seenPaths: Set<String> = []
        let now = Date()

        // 1. Inspect scanned files for installers, archives, temp files, and stale downloads
        if let scanResult {
            for file in scanResult.allFiles {
                let path = file.url.standardizedFileURL.path
                guard !Self.isProtectedSystemPath(path), !seenPaths.contains(path) else { continue }

                let ext = file.fileExtension.lowercased()
                let lowerPath = path.lowercased()
                let ageDays = file.modificationDate.map { now.timeIntervalSince($0) / 86_400 } ?? 0

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
                            whyRecommended: "Installer packages and disk images are typically no longer needed after the application has been installed into /Applications.",
                            potentialConsequences: "If you need to reinstall this version offline later, you would need to download the installer again.",
                            risk: isInDownloads ? .low : .moderate,
                            isSelected: isInDownloads
                        )
                    )
                    continue
                }

                // Old Archives (.zip, .tar.gz, .tgz, .7z, .rar) in Downloads older than 30 days and >= 25 MB
                if ["zip", "gz", "tgz", "7z", "rar", "tar"].contains(ext),
                   lowerPath.contains("/downloads/"),
                   ageDays >= 30,
                   file.size >= 25 * 1024 * 1024 {
                    seenPaths.insert(path)
                    candidates.append(
                        CleanupCandidate(
                            kind: .oldArchives,
                            title: "Old Archive: \(file.name)",
                            whatWillBeRemoved: "Compressed archive '\(file.name)' in Downloads",
                            locationURL: file.url,
                            sizeBytes: file.size,
                            whyRecommended: "This compressed archive in Downloads has not been modified for over \(Int(ageDays)) days and may already be extracted.",
                            potentialConsequences: "Verify that you have already extracted and saved any important files from this archive before moving it to Trash.",
                            risk: .moderate,
                            isSelected: false
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
                            title: "Large Log/Temp File: \(file.name)",
                            whatWillBeRemoved: "Temporary or diagnostic log file '\(file.name)'",
                            locationURL: file.url,
                            sizeBytes: file.size,
                            whyRecommended: "Large log and temporary scratch files accumulate over time and are not required for normal application operation.",
                            potentialConsequences: "Historical diagnostic log entries in this file will no longer be available unless restored from Trash.",
                            risk: .low,
                            isSelected: true
                        )
                    )
                    continue
                }

                // Stale large Downloads (> 90 days old, >= 100 MB)
                if lowerPath.contains("/downloads/"),
                   ageDays >= 90,
                   file.size >= 100 * 1024 * 1024 {
                    seenPaths.insert(path)
                    candidates.append(
                        CleanupCandidate(
                            kind: .unusedDownloads,
                            title: "Stale Download: \(file.name)",
                            whatWillBeRemoved: "Downloaded file '\(file.name)' (last modified \(Int(ageDays)) days ago)",
                            locationURL: file.url,
                            sizeBytes: file.size,
                            whyRecommended: "Large file in your Downloads folder untouched for more than 3 months.",
                            potentialConsequences: "The file will be moved to Trash. Review to ensure it is not an important personal document.",
                            risk: .moderate,
                            isSelected: false
                        )
                    )
                }
            }
        }

        // 2. Include safe measured System Data candidates (Xcode DerivedData, User Logs, Homebrew cache)
        if let systemDataReport {
            for item in systemDataReport.items where item.isUserCleanable && item.recommendation == .recommended {
                guard let url = item.url,
                      let size = item.sizeBytes,
                      size >= 5 * 1024 * 1024,
                      !Self.isProtectedSystemPath(url.path),
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
                let path = dup.url.standardizedFileURL.path
                guard !Self.isProtectedSystemPath(path), !seenPaths.contains(path) else { continue }
                seenPaths.insert(path)
                candidates.append(
                    CleanupCandidate(
                        kind: .duplicateFiles,
                        title: "Duplicate Copy: \(dup.name)",
                        whatWillBeRemoved: "Redundant byte-identical copy '\(dup.name)' (SHA-256 verified)",
                        locationURL: dup.url,
                        sizeBytes: dup.size,
                        whyRecommended: "An identical file with the exact same SHA-256 cryptographic hash is preserved in another location.",
                        potentialConsequences: "Only this redundant copy is moved to Trash; the primary copy remains untouched.",
                        risk: .low,
                        isSelected: true
                    )
                )
            }
        }

        candidates.sort { $0.sizeBytes > $1.sizeBytes }
        return candidates
    }

    /// Safely moves selected URLs to the macOS Trash using `NSWorkspace.shared.recycle`
    /// (falling back to `FileManager.default.trashItem` when needed). Never permanently deletes files.
    public func moveItemsToTrash(urls: [URL], itemSizes: [URL: Int64] = [:]) async -> CleanupExecutionResult {
        var safeURLs: [URL] = []
        var failures: [(path: String, reason: String)] = []

        for url in urls {
            let path = url.standardizedFileURL.path
            if Self.isProtectedSystemPath(path) {
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

        // Sort shortest path first and skip children whose parent is already in safeURLs
        let sortedSafeURLs = safeURLs.sorted { $0.standardizedFileURL.path.count < $1.standardizedFileURL.path.count }
        var processedParentPaths: [String] = []

        for url in sortedSafeURLs {
            let path = url.standardizedFileURL.path
            if processedParentPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                continue
            }
            processedParentPaths.append(path)

            let size = itemSizes[url] ?? (Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))

            // If url is a standard system container directory (like ~/Library/Caches), trash its child items rather than the container root
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
                // Fallback to NSWorkspace recycle for single URL
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
