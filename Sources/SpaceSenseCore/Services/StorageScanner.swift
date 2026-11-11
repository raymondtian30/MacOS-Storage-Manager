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
            "/private/var/vm",
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
        let cleaned = Self.fastCleanPath(URL(fileURLWithPath: path).standardizedFileURL.path)
        return directorySummaryCache[cleaned]?.sizeBytes ?? directorySummaryCache[path]?.sizeBytes
    }

    public func scan(
        rootURL: URL,
        configuration: ScannerConfiguration = ScannerConfiguration(),
        onProgress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> ScanResult {
        let startTime = Date()
        let standardizedRoot = rootURL.standardizedFileURL
        let rootPath = Self.fastCleanPath(standardizedRoot.path)

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardizedRoot.path, isDirectory: &isDir) else {
            throw ScannerError.directoryUnavailable(rootPath)
        }
        guard isDir.boolValue else {
            throw ScannerError.notADirectory(rootPath)
        }
        guard FileManager.default.isReadableFile(atPath: standardizedRoot.path) else {
            throw ScannerError.permissionDenied(rootPath)
        }

        let volumeStats = VolumeStats.forURL(standardizedRoot)
        let normalizedExclusions = Set(
            configuration.excludedPaths.map { Self.fastCleanPath(URL(fileURLWithPath: $0).standardizedFileURL.path) }
        )

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
            .isVolumeKey,
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

        let rootSlashCount = rootPath == "/" ? 0 : Self.countSlashes(in: rootPath)
        var seenResourceIDs: Set<AnyHashable> = []
        var lastProgressEmit = Date.distantPast

        let enumerator = FileManager.default.enumerator(
            at: standardizedRoot,
            includingPropertiesForKeys: resourceKeys,
            options: options,
            errorHandler: { url, _ in
                progress.permissionErrors += 1
                dirAccessible[Self.fastCleanPath(url.path)] = false
                return true
            }
        )

        guard let enumerator else {
            throw ScannerError.permissionDenied(rootPath)
        }

        var loopCounter = 0
        while let itemURL = enumerator.nextObject() as? URL {
            loopCounter += 1
            if loopCounter % 500 == 0 {
                try Task.checkCancellation()
                if loopCounter % 2500 == 0 {
                    await Task.yield()
                }
            }

            let itemPath = Self.fastCleanPath(itemURL.path)

            if shouldExclude(path: itemPath, rootPath: rootPath, excludedPaths: normalizedExclusions) {
                enumerator.skipDescendants()
                continue
            }

            guard let values = try? itemURL.resourceValues(forKeys: resourceKeySet) else {
                progress.permissionErrors += 1
                continue
            }

            // Never follow symbolic links or cross into separate mounted volumes
            if values.isSymbolicLink == true || (values.isVolume == true && itemPath != rootPath) {
                enumerator.skipDescendants()
                continue
            }

            let depth = max(1, Self.countSlashes(in: itemPath) - rootSlashCount)
            if depth == 1 {
                seenTopLevelPaths.insert(itemPath)
            }

            let isDirectory = (values.isDirectory == true) && (values.isPackage != true)
            let isPackage = (values.isPackage == true)
            let modDate = values.contentModificationDate
            let accessDate = values.contentAccessDate ?? modDate
            let parentPath = Self.parentDirectoryPath(of: itemPath, fallback: rootPath)

            if isDirectory {
                progress.directoriesScanned += 1
                progress.currentPath = itemPath
                if depth <= configuration.maxTreeDepth, let modDate {
                    dirModDates[itemPath] = modDate
                }
                parentToChildrenDirs[parentPath, default: []].append(itemPath)
            } else {
                let rawResourceObj = !isPackage ? (values.fileResourceIdentifier as? NSObject) : nil
                if let rawObj = rawResourceObj {
                    let hashKey = AnyHashable(rawObj)
                    if !seenResourceIDs.insert(hashKey).inserted {
                        continue
                    }
                }

                let fileSize: Int64
                let logicalSize: Int64
                if isPackage {
                    fileSize = await calculatePackageSize(at: itemURL, modificationDate: modDate)
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

                let fileName = Self.lastPathComponent(of: itemPath)
                let fileExt = Self.fileExtension(of: fileName)
                let category = StorageCategory.classify(path: itemPath, fileExtension: fileExt, isDirectory: isPackage)
                categoryBytes[category, default: 0] += fileSize

                directDirSizes[parentPath, default: 0] += fileSize
                directDirCounts[parentPath, default: 0] += 1

                let shouldAddLarge = fileSize >= configuration.minimumLargeFileBytes
                let shouldAddAll: Bool
                if !isPackage && logicalSize > 0 {
                    if fileSize >= 5 * 1024 * 1024 {
                        shouldAddAll = true
                    } else if logicalSize >= 1_048_576 && allFiles.count < 15_000 {
                        shouldAddAll = true
                    } else if (logicalSize >= 16_384 || allFiles.count < 250) && allFiles.count < 600 {
                        shouldAddAll = true
                    } else {
                        shouldAddAll = false
                    }
                } else {
                    shouldAddAll = false
                }

                if shouldAddLarge || shouldAddAll {
                    var resourceData: Data?
                    if let rawObj = rawResourceObj {
                        if let nsData = rawObj as? NSData {
                            resourceData = Data(referencing: nsData)
                        } else {
                            var h = rawObj.hash
                            resourceData = Data(bytes: &h, count: MemoryLayout<Int>.size)
                        }
                    }

                    let fileRecord = LargeFileItem(
                        url: itemURL,
                        size: fileSize,
                        logicalSize: logicalSize,
                        modificationDate: modDate,
                        lastAccessDate: accessDate,
                        category: category,
                        resourceIdentifier: resourceData
                    )

                    if shouldAddLarge {
                        largeFiles.append(fileRecord)
                    }
                    if shouldAddAll {
                        allFiles.append(fileRecord)
                    }
                }

                if depth <= configuration.maxTreeDepth {
                    let existingCount = parentToDirectFiles[parentPath]?.count ?? 0
                    let tailSize = parentToDirectFiles[parentPath]?.last?.size ?? 0
                    if existingCount < 80 || fileSize > tailSize {
                        let fileNode = FileNode(
                            url: itemURL,
                            name: fileName,
                            isDirectory: false,
                            size: fileSize,
                            modificationDate: modDate,
                            fileExtension: fileExt,
                            category: category
                        )
                        var list = parentToDirectFiles[parentPath] ?? []
                        list.append(fileNode)
                        if list.count >= 140 {
                            list.sort { $0.size > $1.size }
                            list = Array(list.prefix(60))
                        }
                        parentToDirectFiles[parentPath] = list
                    }
                }
            }

            if let onProgress, loopCounter % 350 == 0 {
                let now = Date()
                if now.timeIntervalSince(lastProgressEmit) >= 0.12 {
                    lastProgressEmit = now
                    let topFraction = min(1.0, Double(seenTopLevelPaths.count) / Double(totalTopLevelCount))
                    let byteFraction = min(0.95, Double(progress.bytesScanned) / Double(max(volumeStats.usedBytes, 1)))
                    progress.progressFraction = min(0.98, max(0.03, max(topFraction * 0.85, byteFraction)))
                    onProgress(progress)
                }
            }
        }

        try Task.checkCancellation()

        var measuredDirectorySizes: [String: Int64] = [:]
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
            measuredDirectorySizes: &measuredDirectorySizes
        )

        progress.progressFraction = 1.0
        onProgress?(progress)

        largeFiles.sort { $0.size > $1.size }
        if largeFiles.count > 500 {
            largeFiles = Array(largeFiles.prefix(500))
        }

        if allFiles.count > 600 {
            allFiles.removeAll { $0.logicalSize < 524_288 && $0.size < 524_288 }
        }
        allFiles.sort { $0.size > $1.size }

        if directorySummaryCache.count > 400 {
            directorySummaryCache.removeAll(keepingCapacity: true)
        }
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
            volumeStats: volumeStats,
            measuredDirectorySizes: measuredDirectorySizes
        )
    }

    public static func fastCleanPath(_ path: String) -> String {
        var result = path
        if result.hasPrefix("/private/var/") || result == "/private/var" {
            result = String(result.dropFirst("/private".count))
        } else if result.hasPrefix("/private/tmp/") || result == "/private/tmp" {
            result = String(result.dropFirst("/private".count))
        } else if result.hasPrefix("/private/etc/") || result == "/private/etc" {
            result = String(result.dropFirst("/private".count))
        }
        if result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    private static func countSlashes(in path: String) -> Int {
        var count = 0
        for byte in path.utf8 where byte == 47 {
            count += 1
        }
        return count
    }

    private static func parentDirectoryPath(of path: String, fallback: String) -> String {
        guard let lastSlash = path.lastIndex(of: "/") else { return fallback }
        if lastSlash == path.startIndex { return "/" }
        return String(path[..<lastSlash])
    }

    private static func lastPathComponent(of path: String) -> String {
        guard path.count > 1, let lastSlash = path.lastIndex(of: "/") else { return path }
        let after = path.index(after: lastSlash)
        return after < path.endIndex ? String(path[after...]) : path
    }

    private static func fileExtension(of fileName: String) -> String {
        guard let dot = fileName.lastIndex(of: "."), dot > fileName.startIndex else { return "" }
        let after = fileName.index(after: dot)
        return after < fileName.endIndex ? fileName[after...].lowercased() : ""
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

    private func calculatePackageSize(at packageURL: URL, modificationDate: Date?) async -> Int64 {
        let key = Self.fastCleanPath(packageURL.path)
        if let modificationDate, let cached = packageSizeCache[key], cached.modificationDate == modificationDate {
            return cached.sizeBytes
        }
        let keys: [URLResourceKey] = [
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
            .fileResourceIdentifierKey
        ]
        let keySet = Set(keys)
        guard let enumerator = FileManager.default.enumerator(
            at: packageURL,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            return 0
        }
        var seenInodes: Set<AnyHashable> = []
        var total: Int64 = 0
        var count = 0
        while let fileURL = enumerator.nextObject() as? URL {
            count += 1
            if count % 400 == 0 {
                if Task.isCancelled {
                    return total
                }
                if count % 2000 == 0 {
                    await Task.yield()
                }
            }
            guard let values = try? fileURL.resourceValues(forKeys: keySet),
                  values.isSymbolicLink != true else {
                continue
            }
            if let rawObj = values.fileResourceIdentifier as? NSObject {
                if !seenInodes.insert(AnyHashable(rawObj)).inserted {
                    continue
                }
            }
            let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
            total += Int64(size)
        }
        if packageSizeCache.count > 300 {
            packageSizeCache.removeAll(keepingCapacity: true)
        }
        packageSizeCache[key] = PackageCacheEntry(modificationDate: modificationDate, sizeBytes: total)
        return total
    }

    private func computeSubtreeTotals(
        path: String,
        directDirSizes: [String: Int64],
        directDirCounts: [String: Int],
        parentToChildrenDirs: [String: [String]]
    ) -> (size: Int64, count: Int) {
        var totalSize = directDirSizes[path] ?? 0
        var totalCount = directDirCounts[path] ?? 0
        if let childDirPaths = parentToChildrenDirs[path] {
            for childPath in childDirPaths {
                let sub = computeSubtreeTotals(
                    path: childPath,
                    directDirSizes: directDirSizes,
                    directDirCounts: directDirCounts,
                    parentToChildrenDirs: parentToChildrenDirs
                )
                totalSize += sub.size
                totalCount += sub.count
            }
        }
        return (totalSize, totalCount)
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
        measuredDirectorySizes: inout [String: Int64]
    ) -> FileNode {
        var totalSize = directDirSizes[path] ?? 0
        var totalCount = directDirCounts[path] ?? 0
        var childrenNodes: [FileNode] = []

        if let childDirPaths = parentToChildrenDirs[path] {
            if currentDepth < maxDepth {
                childrenNodes.reserveCapacity(min(childDirPaths.count, 128))
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
                        measuredDirectorySizes: &measuredDirectorySizes
                    )
                    totalSize += childNode.size
                    totalCount += childNode.itemCount
                    if childNode.size > 0 || !childNode.isAccessible {
                        childrenNodes.append(childNode)
                    }
                }
            } else {
                for childPath in childDirPaths {
                    let sub = computeSubtreeTotals(
                        path: childPath,
                        directDirSizes: directDirSizes,
                        directDirCounts: directDirCounts,
                        parentToChildrenDirs: parentToChildrenDirs
                    )
                    totalSize += sub.size
                    totalCount += sub.count
                }
            }
        }

        if currentDepth < maxDepth, let directFiles = parentToDirectFiles[path] {
            let sortedFiles = directFiles.sorted { $0.size > $1.size }
            childrenNodes.append(contentsOf: sortedFiles.prefix(50))
        }

        if !childrenNodes.isEmpty {
            childrenNodes.sort { $0.size > $1.size }
            let maxChildren = currentDepth <= 1 ? 120 : 60
            if childrenNodes.count > maxChildren {
                childrenNodes = Array(childrenNodes.prefix(maxChildren))
            }
        }

        if currentDepth <= 4 {
            measuredDirectorySizes[path] = totalSize
        }

        let dirName = Self.lastPathComponent(of: path)
        let dirExt = Self.fileExtension(of: dirName)
        let url = URL(fileURLWithPath: path)
        return FileNode(
            url: url,
            name: dirName,
            isDirectory: true,
            size: totalSize,
            modificationDate: dirModDates[path],
            fileExtension: dirExt,
            category: StorageCategory.classify(path: path, fileExtension: dirExt, isDirectory: true),
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
