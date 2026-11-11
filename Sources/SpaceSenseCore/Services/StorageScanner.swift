import Foundation

public struct ScannerConfiguration: Sendable {
    public var minimumLargeFileBytes: Int64
    public var includeHiddenFiles: Bool
    public var excludedPaths: Set<String>
    public var maxTreeDepth: Int

    public init(
        minimumLargeFileBytes: Int64 = 50 * 1024 * 1024, // 50 MB default
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
        let rootPath = standardizedRoot.path

        guard FileManager.default.fileExists(atPath: rootPath) else {
            throw ScannerError.directoryUnavailable(rootPath)
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDir), isDir.boolValue else {
            throw ScannerError.notADirectory(rootPath)
        }

        // Check if readable
        guard FileManager.default.isReadableFile(atPath: rootPath) else {
            throw ScannerError.permissionDenied(rootPath)
        }

        var progress = ScanProgress(currentPath: rootPath)
        var categoryBytes: [StorageCategory: Int64] = [:]
        for cat in StorageCategory.allCases {
            categoryBytes[cat] = 0
        }

        var largeFiles: [LargeFileItem] = []
        var allFiles: [LargeFileItem] = []

        // Track directory sizes and direct files to build a clean hierarchy up to maxTreeDepth
        var dirSizes: [String: Int64] = [rootPath: 0]
        var dirItemCounts: [String: Int] = [rootPath: 0]
        var dirModDates: [String: Date] = [:]
        var dirAccessible: [String: Bool] = [rootPath: true]
        var parentToChildrenDirs: [String: Set<String>] = [:]
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
            .fileResourceIdentifierKey
        ]

        var seenResourceIDs: Set<Data> = []
        let normalizedExclusions = Set(
            configuration.excludedPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        )

        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !configuration.includeHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }

        let rootComponentsCount = standardizedRoot.pathComponents.count
        var lastProgressEmit = Date.distantPast

        let enumerator = FileManager.default.enumerator(
            at: standardizedRoot,
            includingPropertiesForKeys: resourceKeys,
            options: options,
            errorHandler: { url, _ in
                progress.permissionErrors += 1
                dirAccessible[url.standardizedFileURL.path] = false
                return true
            }
        )

        guard let enumerator else {
            throw ScannerError.permissionDenied(rootPath)
        }

        while let item = enumerator.nextObject() as? URL {
            try Task.checkCancellation()

            let itemURL = item.standardizedFileURL
            let itemPath = itemURL.path

            if shouldExclude(path: itemPath, rootPath: rootPath, excludedPaths: normalizedExclusions) {
                enumerator.skipDescendants()
                continue
            }

            let values: URLResourceValues
            do {
                values = try itemURL.resourceValues(forKeys: Set(resourceKeys))
            } catch {
                progress.permissionErrors += 1
                continue
            }

            // Never follow symbolic links recursively
            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let isDirectory = (values.isDirectory == true) && (values.isPackage != true)
            let isPackage = (values.isPackage == true)
            let modDate = values.contentModificationDate

            if isDirectory {
                progress.directoriesScanned += 1
                progress.currentPath = itemPath
                dirModDates[itemPath] = modDate
                if dirSizes[itemPath] == nil {
                    dirSizes[itemPath] = 0
                    dirItemCounts[itemPath] = 0
                }

                // Register in ancestor chain up to maxTreeDepth
                let depth = itemURL.pathComponents.count - rootComponentsCount
                if depth <= configuration.maxTreeDepth {
                    let parentPath = itemURL.deletingLastPathComponent().standardizedFileURL.path
                    parentToChildrenDirs[parentPath, default: []].insert(itemPath)
                }
            } else {
                // Regular file or bundle/package (.app, .photoslibrary, etc.)
                let resourceID = (values.fileResourceIdentifier as? NSData).map { Data(referencing: $0) }
                if !isPackage, let resourceID {
                    if !seenResourceIDs.insert(resourceID).inserted {
                        // Hard link to an already-counted inode in this scan
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

                let fileRecord = LargeFileItem(
                    url: itemURL,
                    size: fileSize,
                    logicalSize: logicalSize,
                    modificationDate: modDate,
                    category: category,
                    resourceIdentifier: resourceID
                )

                if fileSize >= configuration.minimumLargeFileBytes {
                    largeFiles.append(fileRecord)
                }
                // Keep regular files (excluding package directories) for duplicate/cleanup candidates
                if !isPackage && logicalSize > 0 && (logicalSize >= 4096 || allFiles.count < 5_000) && allFiles.count < 100_000 {
                    allFiles.append(fileRecord)
                }

                // Propagate size up to rootPath
                var cursorURL = itemURL.deletingLastPathComponent().standardizedFileURL
                while true {
                    let cursorPath = cursorURL.path
                    dirSizes[cursorPath, default: 0] += fileSize
                    dirItemCounts[cursorPath, default: 0] += 1
                    if cursorPath == rootPath || !cursorPath.hasPrefix(rootPath) || cursorPath == "/" {
                        break
                    }
                    cursorURL = cursorURL.deletingLastPathComponent().standardizedFileURL
                }

                // Attach direct file node if within maxTreeDepth, capping in-memory array per folder
                let parentPath = itemURL.deletingLastPathComponent().standardizedFileURL.path
                let depth = itemURL.pathComponents.count - rootComponentsCount
                if depth <= configuration.maxTreeDepth {
                    let fileNode = FileNode(
                        url: itemURL,
                        isDirectory: false,
                        size: fileSize,
                        modificationDate: modDate,
                        category: category
                    )
                    var list = parentToDirectFiles[parentPath] ?? []
                    if list.count < 120 {
                        list.append(fileNode)
                        parentToDirectFiles[parentPath] = list
                    } else if let minIdx = list.enumerated().min(by: { $0.element.size < $1.element.size })?.offset,
                              fileSize > list[minIdx].size {
                        list[minIdx] = fileNode
                        parentToDirectFiles[parentPath] = list
                    }
                }
            }

            if let onProgress, progress.filesScanned % 250 == 0 {
                let now = Date()
                if now.timeIntervalSince(lastProgressEmit) >= 0.08 {
                    lastProgressEmit = now
                    onProgress(progress)
                }
            }
        }

        try Task.checkCancellation()
        onProgress?(progress)

        largeFiles.sort { $0.size > $1.size }
        if largeFiles.count > 500 {
            largeFiles = Array(largeFiles.prefix(500))
        }

        let rootNode = buildTree(
            at: standardizedRoot,
            currentDepth: 0,
            maxDepth: configuration.maxTreeDepth,
            dirSizes: dirSizes,
            dirItemCounts: dirItemCounts,
            dirModDates: dirModDates,
            dirAccessible: dirAccessible,
            parentToChildrenDirs: parentToChildrenDirs,
            parentToDirectFiles: parentToDirectFiles
        )

        for (dirPath, size) in dirSizes {
            directorySummaryCache[dirPath] = DirectoryCacheSnapshot(
                modificationDate: dirModDates[dirPath],
                sizeBytes: size,
                itemCount: dirItemCounts[dirPath] ?? 0
            )
        }

        let duration = Date().timeIntervalSince(startTime)
        let volumeStats = VolumeStats.forURL(standardizedRoot)

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
            if count % 250 == 0 && Task.isCancelled {
                return total
            }
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true else {
                continue
            }
            let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
            total += Int64(size)
        }
        packageSizeCache[key] = PackageCacheEntry(modificationDate: modificationDate, sizeBytes: total)
        return total
    }

    private func buildTree(
        at url: URL,
        currentDepth: Int,
        maxDepth: Int,
        dirSizes: [String: Int64],
        dirItemCounts: [String: Int],
        dirModDates: [String: Date],
        dirAccessible: [String: Bool],
        parentToChildrenDirs: [String: Set<String>],
        parentToDirectFiles: [String: [FileNode]]
    ) -> FileNode {
        let path = url.path
        let totalSize = dirSizes[path] ?? 0
        let count = dirItemCounts[path] ?? 0
        let modDate = dirModDates[path]
        let accessible = dirAccessible[path] ?? true

        var children: [FileNode] = []
        if currentDepth < maxDepth {
            if let childDirPaths = parentToChildrenDirs[path] {
                for childPath in childDirPaths {
                    let childURL = URL(fileURLWithPath: childPath)
                    let childNode = buildTree(
                        at: childURL,
                        currentDepth: currentDepth + 1,
                        maxDepth: maxDepth,
                        dirSizes: dirSizes,
                        dirItemCounts: dirItemCounts,
                        dirModDates: dirModDates,
                        dirAccessible: dirAccessible,
                        parentToChildrenDirs: parentToChildrenDirs,
                        parentToDirectFiles: parentToDirectFiles
                    )
                    if childNode.size > 0 || !childNode.isAccessible {
                        children.append(childNode)
                    }
                }
            }
            if let directFiles = parentToDirectFiles[path] {
                let sortedFiles = directFiles.sorted { $0.size > $1.size }
                children.append(contentsOf: sortedFiles.prefix(60))
            }
            children.sort { $0.size > $1.size }
        }

        return FileNode(
            url: url,
            isDirectory: true,
            size: totalSize,
            modificationDate: modDate,
            category: StorageCategory.classify(url: url, isDirectory: true),
            itemCount: count,
            isAccessible: accessible,
            children: children
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
