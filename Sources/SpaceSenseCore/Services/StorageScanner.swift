import Foundation

public struct ScannerConfiguration: Sendable {
    public var minimumLargeFileBytes: Int64
    public var includeHiddenFiles: Bool
    public var excludedPaths: Set<String>
    public var maxTreeDepth: Int

    public init(
        minimumLargeFileBytes: Int64 = 250 * 1024 * 1024, // 250 MB default
        includeHiddenFiles: Bool = true,
        excludedPaths: Set<String> = [
            "/dev",
            "/System/Volumes/Data",
            "/System/Volumes/Preboot",
            "/System/Volumes/VM",
            "/System/Volumes/Update",
            "/Volumes"
        ],
        maxTreeDepth: Int = 6
    ) {
        self.minimumLargeFileBytes = minimumLargeFileBytes
        self.includeHiddenFiles = includeHiddenFiles
        self.excludedPaths = excludedPaths
        self.maxTreeDepth = maxTreeDepth
    }
}

public actor StorageScanner {
    private struct PackageCacheEntry {
        let modificationDate: Date?
        let sizeBytes: Int64
    }

    public struct DirectoryCacheSnapshot: Sendable {
        public let modificationDate: Date?
        public let sizeBytes: Int64
        public let itemCount: Int
    }

    private var packageSizeCache: [String: PackageCacheEntry] = [:]
    private var directorySummaryCache: [String: DirectoryCacheSnapshot] = [:]

    public init() {}

    public func clearCache() {
        packageSizeCache.removeAll()
        directorySummaryCache.removeAll()
    }

    public func cachedDirectorySize(for path: String) -> Int64? {
        directorySummaryCache[path]?.sizeBytes
    }

    public func scan(
        rootURL: URL,
        configuration: ScannerConfiguration = ScannerConfiguration(),
        onProgress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> ScanResult {
        let startTime = Date()
        let standardizedRoot = rootURL.standardizedFileURL
        let rootPath = fastCleanPath(standardizedRoot.path)

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDir) else {
            throw ScannerError.directoryUnavailable(rootPath)
        }
        guard isDir.boolValue else {
            throw ScannerError.notADirectory(rootPath)
        }
        guard FileManager.default.isReadableFile(atPath: rootPath) else {
            throw ScannerError.permissionDenied(rootPath)
        }

        let volumeStats = VolumeStats.forURL(standardizedRoot)
        let normalizedExclusions = Set(
            configuration.excludedPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        )

        // Pre-list top-level entries to compute accurate scan percentage
        let topLevelURLs = (try? FileManager.default.contentsOfDirectory(
            at: standardizedRoot,
            includingPropertiesForKeys: nil,
            options: configuration.includeHiddenFiles ? [] : [.skipsHiddenFiles]
        )) ?? []
        let totalTopLevelCount = max(topLevelURLs.count, 1)
        var seenTopLevelPaths: Set<String> = []

        var progress = ScanProgress(currentPath: rootPath, progressFraction: 0.02)
        var categoryBytes: [StorageCategory: Int64] = [:]
        for cat in StorageCategory.allCases {
            categoryBytes[cat] = 0
        }

        var largeFiles: [LargeFileItem] = []
        var allFiles: [LargeFileItem] = []

        // Fast O(1) per-file direct accumulators; rolled up bottom-up at the end
        var directDirSizes: [String: Int64] = [rootPath: 0]
        var directDirCounts: [String: Int] = [rootPath: 0]
        var dirModDates: [String: Date] = [:]
        var dirAccessible: [String: Bool] = [rootPath: true]
        var parentToChildrenDirs: [String: [String]] = [:]
        var parentToDirectFiles: [String: [FileNode]] = [:]

        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isPackageKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .contentAccessDateKey,
            .fileResourceIdentifierKey
        ]
        let resourceKeySet = Set(resourceKeys)

        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !configuration.includeHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }

        let rootSlashCount = countSlashes(in: rootPath)
        var seenResourceIDs: Set<Data> = []
        var lastProgressEmit = Date.distantPast

        let enumerator = FileManager.default.enumerator(
            at: standardizedRoot,
            includingPropertiesForKeys: resourceKeys,
            options: options,
            errorHandler: { url, _ in
                progress.permissionErrors += 1
                dirAccessible[url.path] = false
                return true
            }
        )

        guard let enumerator else {
            throw ScannerError.permissionDenied(rootPath)
        }

        while let itemURL = enumerator.nextObject() as? URL {
            if (progress.filesScanned + progress.directoriesScanned) % 500 == 0 {
                try Task.checkCancellation()
            }

            let itemPath = fastCleanPath(itemURL.path)

            if shouldExclude(path: itemPath, rootPath: rootPath, excludedPaths: normalizedExclusions) {
                enumerator.skipDescendants()
                continue
            }

            guard let values = try? itemURL.resourceValues(forKeys: resourceKeySet) else {
                progress.permissionErrors += 1
                continue
            }

            // Never follow symbolic links recursively
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }

            let depth = max(1, countSlashes(in: itemPath) - rootSlashCount)
            if depth == 1 {
                seenTopLevelPaths.insert(itemPath)
            }

            let isDirectory = (values.isDirectory == true) && (values.isPackage != true)
            let isPackage = (values.isPackage == true)
            let modDate = values.contentModificationDate
            let accessDate = values.contentAccessDate ?? modDate
            let parentPath = parentDirectoryPath(of: itemPath, fallback: rootPath)

            if isDirectory {
                progress.directoriesScanned += 1
                progress.currentPath = itemPath
                if let modDate {
                    dirModDates[itemPath] = modDate
                }
                parentToChildrenDirs[parentPath, default: []].append(itemPath)
            } else {
                let resourceID = (values.fileResourceIdentifier as? NSData).map { Data(referencing: $0) }
                if !isPackage, let resourceID {
                    if !seenResourceIDs.insert(resourceID).inserted {
                        continue
                    }
                }

                let fileSize: Int64
                let logicalSize: Int64
                if isPackage {
                    fileSize = calculatePackageSize(at: itemURL, modificationDate: modDate)
                    logicalSize = fileSize
                } else {
                    logicalSize = Int64(values.fileSize ?? 0)
                    fileSize = Int64(
                        values.totalFileAllocatedSize
                        ?? values.fileAllocatedSize
                        ?? values.fileSize
                        ?? 0
                    )
                }

                progress.filesScanned += 1
                progress.bytesScanned += fileSize

                let category = StorageCategory.classify(url: itemURL, isDirectory: isPackage)
                categoryBytes[category, default: 0] += fileSize

                // O(1) direct parent accumulation
                directDirSizes[parentPath, default: 0] += fileSize
                directDirCounts[parentPath, default: 0] += 1

                let fileRecord = LargeFileItem(
                    url: itemURL,
                    size: fileSize,
                    logicalSize: logicalSize,
                    modificationDate: modDate,
                    lastAccessDate: accessDate,
                    category: category,
                    resourceIdentifier: resourceID
                )

                if fileSize >= configuration.minimumLargeFileBytes {
                    largeFiles.append(fileRecord)
                }

                if !isPackage && logicalSize > 0 && (logicalSize >= 8192 || allFiles.count < 5_000) && allFiles.count < 80_000 {
                    allFiles.append(fileRecord)
                }

                if depth <= configuration.maxTreeDepth {
                    let fileNode = FileNode(
                        url: itemURL,
                        isDirectory: false,
                        size: fileSize,
                        modificationDate: modDate,
                        category: category
                    )
                    var list = parentToDirectFiles[parentPath] ?? []
                    if list.count < 80 {
                        list.append(fileNode)
                        parentToDirectFiles[parentPath] = list
                    } else if let minIdx = list.enumerated().min(by: { $0.element.size < $1.element.size })?.offset,
                              fileSize > list[minIdx].size {
                        list[minIdx] = fileNode
                        parentToDirectFiles[parentPath] = list
                    }
                }
            }

            if let onProgress, (progress.filesScanned + progress.directoriesScanned) % 350 == 0 {
                let now = Date()
                if now.timeIntervalSince(lastProgressEmit) >= 0.12 {
                    lastProgressEmit = now
                    let topFraction = Double(seenTopLevelPaths.count) / Double(totalTopLevelCount)
                    let byteFraction = min(0.95, Double(progress.bytesScanned) / Double(max(volumeStats.usedBytes, 1)))
                    progress.progressFraction = min(0.98, max(0.03, max(topFraction * 0.85, byteFraction)))
                    onProgress(progress)
                }
            }
        }

        try Task.checkCancellation()

        // Roll up directory sizes and Build FileNode tree bottom-up
        var totalDirSizes: [String: Int64] = [:]
        var totalDirCounts: [String: Int] = [:]

        let rootNode = buildTreeBottomUp(
            path: rootPath,
            currentDepth: 0,
            maxDepth: configuration.maxTreeDepth,
            directDirSizes: directDirSizes,
            directDirCounts: directDirCounts,
            dirModDates: dirModDates,
            dirAccessible: dirAccessible,
            parentToChildrenDirs: parentToChildrenDirs,
            parentToDirectFiles: parentToDirectFiles,
            totalDirSizes: &totalDirSizes,
            totalDirCounts: &totalDirCounts
        )

        progress.progressFraction = 1.0
        onProgress?(progress)

        largeFiles.sort { $0.size > $1.size }
        if largeFiles.count > 500 {
            largeFiles = Array(largeFiles.prefix(500))
        }

        // Cache top 200 largest directory summaries to bound memory
        directorySummaryCache[rootPath] = DirectoryCacheSnapshot(
            modificationDate: dirModDates[rootPath],
            sizeBytes: rootNode.size,
            itemCount: rootNode.itemCount
        )
        for child in rootNode.children where child.isDirectory {
            directorySummaryCache[child.url.path] = DirectoryCacheSnapshot(
                modificationDate: child.modificationDate,
                sizeBytes: child.size,
                itemCount: child.itemCount
            )
        }

        let duration = Date().timeIntervalSince(startTime)

        return ScanResult(
            timestamp: Date(),
            rootURL: standardizedRoot,
            durationSeconds: duration,
            rootNode: rootNode,
            categoryBytes: categoryBytes,
            largeFiles: largeFiles,
            allFiles: allFiles,
            totalFilesScanned: progress.filesScanned,
            totalDirectoriesScanned: progress.directoriesScanned,
            permissionErrorCount: progress.permissionErrors,
            volumeStats: volumeStats
        )
    }

    private func fastCleanPath(_ path: String) -> String {
        var result = path
        if result.hasPrefix("/private/var/") {
            result = String(result.dropFirst("/private".count))
        } else if result.hasPrefix("/private/tmp/") {
            result = String(result.dropFirst("/private".count))
        }
        if result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    private func countSlashes(in path: String) -> Int {
        var count = 0
        for byte in path.utf8 where byte == 47 { // '/'
            count += 1
        }
        return count
    }

    private func parentDirectoryPath(of path: String, fallback: String) -> String {
        guard let lastSlash = path.lastIndex(of: "/") else { return fallback }
        if lastSlash == path.startIndex { return "/" }
        return String(path[..<lastSlash])
    }

    private func shouldExclude(path: String, rootPath: String, excludedPaths: Set<String>) -> Bool {
        if path == rootPath { return false }
        for excluded in excludedPaths {
            if path == excluded || path.hasPrefix(excluded + "/") {
                if rootPath != excluded && !rootPath.hasPrefix(excluded + "/") {
                    return true
                }
            }
        }
        return false
    }

    private func calculatePackageSize(at packageURL: URL, modificationDate: Date?) -> Int64 {
        let key = packageURL.path
        if let cached = packageSizeCache[key], cached.modificationDate == modificationDate, modificationDate != nil {
            return cached.sizeBytes
        }
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        let keySet = Set(keys)
        guard let enumerator = FileManager.default.enumerator(
            at: packageURL,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            return 0
        }
        var total: Int64 = 0
        var count = 0
        while let fileURL = enumerator.nextObject() as? URL {
            count += 1
            if count % 400 == 0 && Task.isCancelled {
                return total
            }
            guard let values = try? fileURL.resourceValues(forKeys: keySet),
                  values.isSymbolicLink != true else {
                continue
            }
            let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
            total += Int64(size)
        }
        packageSizeCache[key] = PackageCacheEntry(modificationDate: modificationDate, sizeBytes: total)
        return total
    }

    private func buildTreeBottomUp(
        path: String,
        currentDepth: Int,
        maxDepth: Int,
        directDirSizes: [String: Int64],
        directDirCounts: [String: Int],
        dirModDates: [String: Date],
        dirAccessible: [String: Bool],
        parentToChildrenDirs: [String: [String]],
        parentToDirectFiles: [String: [FileNode]],
        totalDirSizes: inout [String: Int64],
        totalDirCounts: inout [String: Int]
    ) -> FileNode {
        var totalSize = directDirSizes[path] ?? 0
        var totalCount = directDirCounts[path] ?? 0
        var childrenNodes: [FileNode] = []

        if let childDirPaths = parentToChildrenDirs[path] {
            for childPath in childDirPaths {
                let childNode = buildTreeBottomUp(
                    path: childPath,
                    currentDepth: currentDepth + 1,
                    maxDepth: maxDepth,
                    directDirSizes: directDirSizes,
                    directDirCounts: directDirCounts,
                    dirModDates: dirModDates,
                    dirAccessible: dirAccessible,
                    parentToChildrenDirs: parentToChildrenDirs,
                    parentToDirectFiles: parentToDirectFiles,
                    totalDirSizes: &totalDirSizes,
                    totalDirCounts: &totalDirCounts
                )
                totalSize += childNode.size
                totalCount += childNode.itemCount
                if currentDepth < maxDepth && (childNode.size > 0 || !childNode.isAccessible) {
                    childrenNodes.append(childNode)
                }
            }
        }

        if currentDepth < maxDepth, let directFiles = parentToDirectFiles[path] {
            let sortedFiles = directFiles.sorted { $0.size > $1.size }
            childrenNodes.append(contentsOf: sortedFiles.prefix(50))
            childrenNodes.sort { $0.size > $1.size }
        }

        totalDirSizes[path] = totalSize
        totalDirCounts[path] = totalCount

        let url = URL(fileURLWithPath: path)
        return FileNode(
            url: url,
            isDirectory: true,
            size: totalSize,
            modificationDate: dirModDates[path],
            category: StorageCategory.classify(url: url, isDirectory: true),
            itemCount: totalCount,
            isAccessible: dirAccessible[path] ?? true,
            children: childrenNodes
        )
    }
}

public enum ScannerError: LocalizedError, Sendable {
    case directoryUnavailable(String)
    case notADirectory(String)
    case permissionDenied(String)
    case scanCancelled

    public var errorDescription: String? {
        switch self {
        case .directoryUnavailable(let path):
            return "The directory at '\(path)' is no longer available or does not exist."
        case .notADirectory(let path):
            return "The selected path '\(path)' is a file, not a directory."
        case .permissionDenied(let path):
            return "Permission denied when trying to read '\(path)'. Grant access or choose another folder."
        case .scanCancelled:
            return "The storage scan was cancelled."
        }
    }
}
