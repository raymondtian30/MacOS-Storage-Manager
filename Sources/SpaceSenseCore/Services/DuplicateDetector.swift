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

    /// Finds exact duplicate files using a 3-stage pipeline:
    /// 1. Group files by exact byte size (filtering out files smaller than `minimumBytes`).
    /// 2. For groups with >1 file, compute a fast partial SHA-256 hash (first 32 KB + last 32 KB) for files > 64 KB.
    /// 3. For matching partial hashes, compute the full streaming SHA-256 digest using CryptoKit.
    public func findDuplicates(
        in candidates: [LargeFileItem],
        minimumBytes: Int64 = 100 * 1024, // 100 KB default
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [DuplicateGroup] {
        try Task.checkCancellation()

        // Stage 1: Group by exact logical byte size (never group by filename) and deduplicate hard links
        var sizeGroups: [Int64: [LargeFileItem]] = [:]
        var seenInodes: Set<Data> = []
        for item in candidates where item.logicalSize >= minimumBytes {
            if let inode = item.resourceIdentifier {
                if !seenInodes.insert(inode).inserted {
                    continue
                }
            }
            sizeGroups[item.logicalSize, default: []].append(item)
        }

        let potentialBySize = sizeGroups.values.filter { $0.count > 1 }
        let totalCandidateFiles = potentialBySize.reduce(0) { $0 + $1.count }
        var processedFiles = 0

        var duplicateGroups: [DuplicateGroup] = []

        for group in potentialBySize {
            try Task.checkCancellation()
            guard let logicalFileSize = group.first?.logicalSize else { continue }

            // Stage 2: Partial hash check for files > 64 KB
            let partialThreshold: Int64 = 64 * 1024
            var partialBuckets: [String: [LargeFileItem]] = [:]

            if logicalFileSize > partialThreshold {
                for file in group {
                    try Task.checkCancellation()
                    if let pHash = computePartialSHA256(for: file) {
                        partialBuckets[pHash, default: []].append(file)
                    } else {
                        processedFiles += 1
                        onProgress?(processedFiles, max(totalCandidateFiles, 1))
                    }
                }
            } else {
                partialBuckets["small-file-direct-full-hash"] = group
            }

            // Account for Stage 2 non-colliding files in progress
            for (_, subGroup) in partialBuckets where subGroup.count == 1 {
                processedFiles += 1
                onProgress?(processedFiles, max(totalCandidateFiles, 1))
            }

            // Stage 3: Full SHA-256 hash for files that collided on size + partial hash
            for (_, subGroup) in partialBuckets where subGroup.count > 1 {
                var fullBuckets: [String: [LargeFileItem]] = [:]
                for file in subGroup {
                    try Task.checkCancellation()
                    if let fullHash = try computeFullSHA256(for: file) {
                        fullBuckets[fullHash, default: []].append(file)
                    }
                    processedFiles += 1
                    onProgress?(processedFiles, max(totalCandidateFiles, 1))
                }

                for (sha256, matchedFiles) in fullBuckets where matchedFiles.count > 1 {
                    // Sort so oldest or shortest-path original stays first (unmarked), newer copies can be reviewed
                    let sorted = matchedFiles.sorted { lhs, rhs in
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
                            size: item.logicalSize,
                            modificationDate: item.modificationDate,
                            isMarkedForRemoval: index > 0 // Keep first copy by default
                        )
                    }

                    duplicateGroups.append(
                        DuplicateGroup(
                            sha256Hash: sha256,
                            fileSize: logicalFileSize,
                            files: items
                        )
                    )
                }
            }
        }

        duplicateGroups.sort { $0.reclaimableBytes > $1.reclaimableBytes }
        return duplicateGroups
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
        guard let handle = try? FileHandle(forReadingFrom: item.url) else {
            return nil
        }
        defer { try? handle.close() }

        let chunkSize = 32 * 1024
        var hasher = SHA256()

        guard let headData = try? handle.read(upToCount: chunkSize) else {
            return nil
        }
        hasher.update(data: headData)

        if item.logicalSize > Int64(chunkSize * 2) {
            let tailOffset = UInt64(max(0, item.logicalSize - Int64(chunkSize)))
            if (try? handle.seek(toOffset: tailOffset)) != nil,
               let tailData = try? handle.read(upToCount: chunkSize) {
                hasher.update(data: tailData)
            }
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        partialHashCache[key] = digest
        return digest
    }

    private func computeFullSHA256(for item: LargeFileItem) throws -> String? {
        let key = cacheKey(for: item)
        if let cached = fullHashCache[key] {
            return cached
        }
        guard let handle = try? FileHandle(forReadingFrom: item.url) else {
            return nil
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        let bufferSize = 256 * 1024

        while true {
            try Task.checkCancellation()
            guard let chunk = try? handle.read(upToCount: bufferSize), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        fullHashCache[key] = digest
        return digest
    }
}
