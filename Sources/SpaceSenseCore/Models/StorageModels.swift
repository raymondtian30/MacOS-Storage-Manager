import Foundation
import SwiftUI

public enum NavigationSection: String, CaseIterable, Identifiable, Sendable {
    case overview = "Overview"
    case analyzer = "Storage Analyzer"
    case deleteHub = "Delete Hub"
    case systemData = "System Data"
    case history = "Storage History"
    case aiAssistant = "AI Assistant"
    case settings = "Settings"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.bottom.50percent"
        case .analyzer: return "square.grid.3x2.fill"
        case .deleteHub: return "trash.slash.fill"
        case .systemData: return "externaldrive.fill.badge.timemachine"
        case .history: return "chart.xyaxis.line"
        case .aiAssistant: return "sparkles.rectangle.stack.fill"
        case .settings: return "gearshape.fill"
        }
    }

    public var subtitle: String {
        switch self {
        case .overview: return "Disk health, category breakdown, and recent activity"
        case .analyzer: return "Interactive treemap and hierarchical folder browser"
        case .deleteHub: return "Unified hub for unused large files, duplicates, caches, and safe cleanup"
        case .systemData: return "Inspect caches, logs, developer artifacts, and system folders"
        case .history: return "Track storage utilization and growing folders over time"
        case .aiAssistant: return "Ask your AI model questions grounded in actual scan data"
        case .settings: return "API keys, thresholds, scan exclusions, updates, and credits"
        }
    }
}

public enum StorageCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case applications = "Applications"
    case documents = "Documents"
    case downloads = "Downloads"
    case photosAndMedia = "Photos & Media"
    case developer = "Developer Files"
    case systemData = "System Data"
    case other = "Other"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .applications: return "app.badge.fill"
        case .documents: return "doc.text.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .photosAndMedia: return "photo.stack.fill"
        case .developer: return "hammer.fill"
        case .systemData: return "internaldrive.fill"
        case .other: return "folder.fill"
        }
    }

    /// Cohesive 3-color palette (Electric Cyan, Emerald Mint, and Cool Slate tones)
    public var color: Color {
        switch self {
        case .applications: return Color(red: 0.22, green: 0.68, blue: 0.96)
        case .documents: return Color(red: 0.20, green: 0.82, blue: 0.64)
        case .downloads: return Color(red: 0.22, green: 0.68, blue: 0.96).opacity(0.78)
        case .photosAndMedia: return Color(red: 0.20, green: 0.82, blue: 0.64).opacity(0.78)
        case .developer: return Color(red: 0.22, green: 0.68, blue: 0.96).opacity(0.58)
        case .systemData: return Color(red: 0.46, green: 0.54, blue: 0.66)
        case .other: return Color(red: 0.46, green: 0.54, blue: 0.66).opacity(0.68)
        }
    }

    public static func classify(url: URL, isDirectory: Bool = false) -> StorageCategory {
        let path = url.path
        let lowerPath = path.lowercased()
        let ext = url.pathExtension.lowercased()

        if lowerPath.contains("/applications/") || ext == "app" {
            return .applications
        }
        if lowerPath.contains("/downloads/") || lowerPath.hasSuffix("/downloads") {
            return .downloads
        }
        if (lowerPath.contains("/library/") && !lowerPath.contains("/library/developer/")) ||
            lowerPath.hasPrefix("/system/") ||
            lowerPath.hasPrefix("/private/") ||
            lowerPath.hasPrefix("/var/") ||
            lowerPath.hasPrefix("/usr/") {
            return .systemData
        }
        if lowerPath.contains("/developer/") ||
            lowerPath.contains("/deriveddata/") ||
            lowerPath.contains("/coresimulator/") ||
            lowerPath.contains("/node_modules/") ||
            lowerPath.contains("/.git/") ||
            lowerPath.contains("/.cargo/") ||
            lowerPath.contains("/.gradle/") ||
            ["swift", "xcodeproj", "xcworkspace", "py", "js", "ts", "tsx", "rs", "go", "c", "cpp", "h", "java", "kt", "o", "dylib", "a"].contains(ext) {
            return .developer
        }
        if lowerPath.contains("/pictures/") ||
            lowerPath.contains("/movies/") ||
            lowerPath.contains("/music/") ||
            ["jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "raw", "cr2", "dng", "mp4", "mov", "mkv", "avi", "mp3", "wav", "aac", "flac", "m4a"].contains(ext) {
            return .photosAndMedia
        }
        if lowerPath.contains("/documents/") ||
            lowerPath.contains("/desktop/") ||
            ["pdf", "doc", "docx", "txt", "rtf", "md", "pages", "numbers", "key", "xls", "xlsx", "ppt", "pptx", "csv", "epub"].contains(ext) {
            return .documents
        }
        return .other
    }
}

public struct VolumeStats: Codable, Equatable, Sendable {
    public let volumeName: String
    public let mountPoint: String
    public let totalBytes: Int64
    public let availableBytes: Int64
    public let usedBytes: Int64
    public let isReadOnly: Bool

    public init(
        volumeName: String,
        mountPoint: String,
        totalBytes: Int64,
        availableBytes: Int64,
        usedBytes: Int64,
        isReadOnly: Bool = false
    ) {
        self.volumeName = volumeName
        self.mountPoint = mountPoint
        self.totalBytes = max(totalBytes, 1)
        self.availableBytes = max(availableBytes, 0)
        self.usedBytes = max(usedBytes, 0)
        self.isReadOnly = isReadOnly
    }

    public var utilizationPercentage: Double {
        guard totalBytes > 0 else { return 0 }
        return min(100.0, max(0.0, (Double(usedBytes) / Double(totalBytes)) * 100.0))
    }

    public static func currentBootVolume() -> VolumeStats {
        forURL(URL(fileURLWithPath: "/"))
    }

    public static func forURL(_ url: URL) -> VolumeStats {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeURLKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeIsReadOnlyKey
        ]
        if let values = try? url.resourceValues(forKeys: keys) {
            let name = values.volumeName ?? "Macintosh HD"
            let mount = values.volume?.path ?? "/"
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let availableImportant = values.volumeAvailableCapacityForImportantUsage ?? 0
            let availableStandard = Int64(values.volumeAvailableCapacity ?? 0)
            let available = availableImportant > 0 ? availableImportant : availableStandard
            let used = max(0, total - available)
            let readOnly = values.volumeIsReadOnly ?? false
            return VolumeStats(
                volumeName: name,
                mountPoint: mount,
                totalBytes: total,
                availableBytes: available,
                usedBytes: used,
                isReadOnly: readOnly
            )
        }
        return VolumeStats(
            volumeName: "Unknown Volume",
            mountPoint: url.path,
            totalBytes: 1,
            availableBytes: 0,
            usedBytes: 0
        )
    }
}

public struct FileNode: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modificationDate: Date?
    public let fileExtension: String
    public let category: StorageCategory
    public let itemCount: Int
    public let isAccessible: Bool
    public var children: [FileNode]

    public init(
        url: URL,
        name: String? = nil,
        isDirectory: Bool,
        size: Int64,
        modificationDate: Date? = nil,
        fileExtension: String? = nil,
        category: StorageCategory? = nil,
        itemCount: Int = 1,
        isAccessible: Bool = true,
        children: [FileNode] = []
    ) {
        self.id = url.path
        self.url = url
        self.name = name ?? (url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
        self.fileExtension = fileExtension ?? url.pathExtension.lowercased()
        self.category = category ?? StorageCategory.classify(url: url, isDirectory: isDirectory)
        self.itemCount = itemCount
        self.isAccessible = isAccessible
        self.children = children
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        lhs.id == rhs.id &&
        lhs.size == rhs.size &&
        lhs.itemCount == rhs.itemCount &&
        lhs.isAccessible == rhs.isAccessible &&
        lhs.children.count == rhs.children.count
    }
}

public struct LargeFileItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let path: String
    public let size: Int64
    public let logicalSize: Int64
    public let modificationDate: Date?
    public let lastAccessDate: Date?
    public let fileExtension: String
    public let category: StorageCategory
    public let resourceIdentifier: Data?

    public init(
        url: URL,
        size: Int64,
        logicalSize: Int64? = nil,
        modificationDate: Date?,
        lastAccessDate: Date? = nil,
        category: StorageCategory? = nil,
        resourceIdentifier: Data? = nil
    ) {
        self.id = url.path
        self.url = url
        self.name = url.lastPathComponent
        self.path = url.path
        self.size = size
        self.logicalSize = logicalSize ?? size
        self.modificationDate = modificationDate
        self.lastAccessDate = lastAccessDate ?? modificationDate
        self.fileExtension = url.pathExtension.lowercased()
        self.category = category ?? StorageCategory.classify(url: url, isDirectory: false)
        self.resourceIdentifier = resourceIdentifier
    }

    public var lastUsedDate: Date? {
        if let access = lastAccessDate, let mod = modificationDate {
            return max(access, mod)
        }
        return lastAccessDate ?? modificationDate
    }

    public func daysSinceLastOpened(from referenceDate: Date = Date()) -> Int {
        guard let lastUsed = lastUsedDate else { return 0 }
        return max(0, Int(referenceDate.timeIntervalSince(lastUsed) / 86_400))
    }
}

public struct DuplicateFileItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let path: String
    public let size: Int64
    public let modificationDate: Date?
    public var isMarkedForRemoval: Bool

    public init(
        url: URL,
        size: Int64,
        modificationDate: Date?,
        isMarkedForRemoval: Bool = false
    ) {
        self.id = url.path
        self.url = url
        self.name = url.lastPathComponent
        self.path = url.path
        self.size = size
        self.modificationDate = modificationDate
        self.isMarkedForRemoval = isMarkedForRemoval
    }
}

public struct DuplicateGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let sha256Hash: String
    public let fileSize: Int64
    public var files: [DuplicateFileItem]

    public init(sha256Hash: String, fileSize: Int64, files: [DuplicateFileItem]) {
        self.id = sha256Hash
        self.sha256Hash = sha256Hash
        self.fileSize = fileSize
        self.files = files
    }

    public var reclaimableBytes: Int64 {
        guard files.count > 1 else { return 0 }
        return fileSize * Int64(files.count - 1)
    }

    public var selectedReclaimableBytes: Int64 {
        let selectedCount = files.filter(\.isMarkedForRemoval).count
        return fileSize * Int64(selectedCount)
    }
}

public struct ScanProgress: Sendable {
    public var filesScanned: Int
    public var directoriesScanned: Int
    public var bytesScanned: Int64
    public var currentPath: String
    public var permissionErrors: Int
    public var progressFraction: Double

    public var percent: Double {
        min(100.0, max(0.0, progressFraction * 100.0))
    }

    public init(
        filesScanned: Int = 0,
        directoriesScanned: Int = 0,
        bytesScanned: Int64 = 0,
        currentPath: String = "",
        permissionErrors: Int = 0,
        progressFraction: Double = 0.0
    ) {
        self.filesScanned = filesScanned
        self.directoriesScanned = directoriesScanned
        self.bytesScanned = bytesScanned
        self.currentPath = currentPath
        self.permissionErrors = permissionErrors
        self.progressFraction = min(1.0, max(0.0, progressFraction))
    }
}

public struct ScanResult: Sendable {
    public let id: UUID
    public let timestamp: Date
    public let rootURL: URL
    public let durationSeconds: TimeInterval
    public let rootNode: FileNode
    public let categoryBytes: [StorageCategory: Int64]
    public let largeFiles: [LargeFileItem]
    public let allFiles: [LargeFileItem]
    public let totalFilesScanned: Int
    public let totalDirectoriesScanned: Int
    public let permissionErrorCount: Int
    public let volumeStats: VolumeStats

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        rootURL: URL,
        durationSeconds: TimeInterval,
        rootNode: FileNode,
        categoryBytes: [StorageCategory: Int64],
        largeFiles: [LargeFileItem],
        allFiles: [LargeFileItem],
        totalFilesScanned: Int,
        totalDirectoriesScanned: Int,
        permissionErrorCount: Int,
        volumeStats: VolumeStats
    ) {
        self.id = id
        self.timestamp = timestamp
        self.rootURL = rootURL
        self.durationSeconds = durationSeconds
        self.rootNode = rootNode
        self.categoryBytes = categoryBytes
        self.largeFiles = largeFiles
        self.allFiles = allFiles
        self.totalFilesScanned = totalFilesScanned
        self.totalDirectoriesScanned = totalDirectoriesScanned
        self.permissionErrorCount = permissionErrorCount
        self.volumeStats = volumeStats
    }
}

public enum ByteFormatting {
    public static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    public static func compactString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter.string(fromByteCount: bytes)
    }
}
