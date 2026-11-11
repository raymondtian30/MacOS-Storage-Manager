import Foundation
import CryptoKit

public actor DuplicateDetector {
    private struct FileDigestCacheKey: Hashable {
        let path: String
        let size: Int64
        let modificationTimeInterval: TimeInterval
    }

    private var partialHashCache: [FileDigestCacheKey: String] = [:]
    private var fullHashCache: [FileDigestCacheKey: String] = [:]

    public init() {}

    public func clearCache() {
        partialHashCache.removeAll()
        fullHashCache.removeAll()
    }

    private static let excludedDuplicateSubstrings: [String] = [
        "/Library/Caches/",
        "/Library/Logs/",
        "/Library/Developer/",
        "/Library/Containers/",
        "/Library/Group Containers/",
        "/Library/WebKit/",
        "/Library/Metadata/",
        "/Library/HTTPStorages/",
        "/Library/Saved Application State/",
        "/node_modules/",
        "/.git/",
        "/.cargo/",
        "/.gradle/",
        "/.npm/",
        "/.Trash/"
    ]

    private static func shouldSkipDuplicateCandidate(path: String) -> Bool {
        if SmartCleanupEngine.isProtectedSystemPath(path, resolveSymlinks: false) {
            return true
        }
        for sub in excludedDuplicateSubstrings {
            if path.contains(sub) {
                return true
            }
        }
        return false
    }

    /// Finds exact duplicate files using a 3-stage pipeline:
    /// 1. Group files by exact logical byte size (excluding hard links and dataless cloud files).
    /// 2. For groups with >1 file, compute a fast partial SHA-256 hash (first 32 KB + last 32 KB) for files > 64 KB.
    /// 3. For matching partial hashes, compute the full streaming SHA-256 digest using CryptoKit, verifying total bytes read.
    public func findDuplicates(
        in candidates: [LargeFileItem],
        minimumBytes: Int64 = 100 * 1024,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [DuplicateGroup] {
        try Task.checkCancellation()

        var sizeGroups: [Int64: [LargeFileItem]] = [:]
        var seenInodes: Set<Data> = []
        for item in candidates where item.logicalSize >= minimumBytes && item.size > 0 {
            if Self.shouldSkipDuplicateCandidate(path: item.path) {
                continue
            }
            if let inode = item.resourceIdentifier {
                if !seenInodes.insert(inode).inserted {
                    continue
                }
            }
            sizeGroups[item.logicalSize, default: []].append(item)
        }

        let potentialBySize = sizeGroups.values.filter { $0.count > 1 }
        let totalCandidateFiles = potentialBySize.reduce(0) { $0 + $1.count }
        let safeTotal = max(totalCandidateFiles, 1)
        var processedFiles = 0
        var lastProgressEmit = Date.distantPast
        var opsSinceYield = 0

        func emitProgressIfNeeded(force: Bool = false) {
            guard let onProgress else { return }
            let now = Date()
            if force || now.timeIntervalSince(lastProgressEmit) >= 0.15 {
                lastProgressEmit = now
                onProgress(processedFiles, safeTotal)
            }
        }

        var duplicateGroups: [DuplicateGroup] = []

        for group in potentialBySize {
            try Task.checkCancellation()
            opsSinceYield += 1
            if opsSinceYield % 24 == 0 {
                await Task.yield()
            }
            guard let logicalFileSize = group.first?.logicalSize else { continue }

            let partialThreshold: Int64 = 64 * 1024
            var partialBuckets: [String: [LargeFileItem]] = [:]

            if logicalFileSize > partialThreshold {
                for file in group {
                    try Task.checkCancellation()
                    opsSinceYield += 1
                    if opsSinceYield % 32 == 0 {
                        await Task.yield()
                    }
                    if let pHash = computePartialSHA256(for: file) {
                        partialBuckets[pHash, default: []].append(file)
                    } else {
                        processedFiles += 1
                        emitProgressIfNeeded()
                    }
                }
            } else {
                partialBuckets["small-file-direct-full-hash"] = group
            }

            for (_, subGroup) in partialBuckets where subGroup.count == 1 {
                processedFiles += 1
                emitProgressIfNeeded()
            }

            for (_, subGroup) in partialBuckets where subGroup.count > 1 {
                var fullBuckets: [String: [LargeFileItem]] = [:]
                let skipAvail = logicalFileSize > partialThreshold
                for file in subGroup {
                    try Task.checkCancellation()
                    if let fullHash = try await computeFullSHA256(for: file, skipAvailabilityCheck: skipAvail) {
                        fullBuckets[fullHash, default: []].append(file)
                    }
                    processedFiles += 1
                    emitProgressIfNeeded()
                }

                for (sha256, matchedFiles) in fullBuckets where matchedFiles.count > 1 {
                    // Prefer keeping files in Documents/Desktop over copies in Downloads/Caches
                    let sorted = matchedFiles.sorted { lhs, rhs in
                        let lPriority = Self.locationRetentionPriority(for: lhs.path)
                        let rPriority = Self.locationRetentionPriority(for: rhs.path)
                        if lPriority != rPriority {
                            return lPriority > rPriority
                        }
                        let lDate = lhs.modificationDate ?? .distantPast
                        let rDate = rhs.modificationDate ?? .distantPast
                        if lDate != rDate {
                            return lDate < rDate
                        }
                        return lhs.path.count < rhs.path.count
                    }

                    let items = sorted.enumerated().map { index, item in
                        DuplicateFileItem(
                            url: item.url,
                            size: item.size,
                            modificationDate: item.modificationDate,
                            isMarkedForRemoval: index > 0
                        )
                    }

                    duplicateGroups.append(
                        DuplicateGroup(
                            sha256Hash: sha256,
                            fileSize: sorted.first?.size ?? logicalFileSize,
                            files: items
                        )
                    )
                }
            }
        }

        emitProgressIfNeeded(force: true)
        duplicateGroups.sort { $0.reclaimableBytes > $1.reclaimableBytes }
        return duplicateGroups
    }

    private static let hexAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

    private static func hexString(from digest: SHA256Digest) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        for byte in digest {
            bytes.append(hexAlphabet[Int(byte >> 4)])
            bytes.append(hexAlphabet[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func locationRetentionPriority(for path: String) -> Int {
        let lower = path.lowercased()
        if lower.contains("/trash/") || lower.contains("/.trash/") || lower.contains("/caches/") {
            return 0
        }
        if lower.contains("/downloads/") {
            return 1
        }
        if lower.contains("/documents/") || lower.contains("/desktop/") || lower.contains("/pictures/") {
            return 3
        }
        return 2
    }

    private func isLocallyAvailable(_ url: URL) -> Bool {
        if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
           let status = values.ubiquitousItemDownloadingStatus,
           status != .current {
            return false
        }
        return true
    }

    private func cacheKey(for item: LargeFileItem) -> FileDigestCacheKey {
        FileDigestCacheKey(
            path: item.path,
            size: item.logicalSize,
            modificationTimeInterval: item.modificationDate?.timeIntervalSince1970 ?? 0
        )
    }

    private func computePartialSHA256(for item: LargeFileItem) -> String? {
        let key = cacheKey(for: item)
        if let cached = partialHashCache[key] {
            return cached
        }
        guard isLocallyAvailable(item.url),
              let handle = try? FileHandle(forReadingFrom: item.url) else {
            return nil
        }
        defer { try? handle.close() }

        let chunkSize = 32 * 1024
        var hasher = SHA256()

        guard let headData = try? handle.read(upToCount: chunkSize), !headData.isEmpty else {
            return nil
        }
        hasher.update(data: headData)

        if item.logicalSize > Int64(chunkSize * 2) {
            let tailOffset = UInt64(max(0, item.logicalSize - Int64(chunkSize)))
            guard (try? handle.seek(toOffset: tailOffset)) != nil,
                  let tailData = try? handle.read(upToCount: chunkSize),
                  tailData.count == chunkSize else {
                return nil
            }
            hasher.update(data: tailData)
        }

        let digest = Self.hexString(from: hasher.finalize())
        if partialHashCache.count > 10_000 {
            partialHashCache.removeAll(keepingCapacity: true)
        }
        partialHashCache[key] = digest
        return digest
    }

    private func computeFullSHA256(for item: LargeFileItem, skipAvailabilityCheck: Bool = false) async throws -> String? {
        let key = cacheKey(for: item)
        if let cached = fullHashCache[key] {
            return cached
        }
        if !skipAvailabilityCheck && !isLocallyAvailable(item.url) {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: item.url) else {
            return nil
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        let bufferSize = 512 * 1024
        var totalBytesRead: Int64 = 0
        var chunksRead = 0

        while true {
            try Task.checkCancellation()
            chunksRead += 1
            if chunksRead % 16 == 0 {
                await Task.yield()
            }
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: bufferSize)
            } catch {
                // Never treat a mid-stream read error as EOF
                return nil
            }
            guard let chunk, !chunk.isEmpty else {
                break
            }
            totalBytesRead += Int64(chunk.count)
            hasher.update(data: chunk)
        }

        guard totalBytesRead == item.logicalSize, totalBytesRead > 0 else {
            return nil
        }

        let digest = Self.hexString(from: hasher.finalize())
        if fullHashCache.count > 5_000 {
            fullHashCache.removeAll(keepingCapacity: true)
        }
        fullHashCache[key] = digest
        return digest
    }
}
