import Foundation
import SwiftUI

public enum CleanupKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case unusedLargeFiles = "Unused Large Files"
    case duplicateFiles = "Exact Duplicates"
    case applicationCaches = "Caches & Logs"
    case developerArtifacts = "Developer Artifacts"
    case oldInstallers = "Installers & Disk Images"
    case oldArchives = "Old Archives"
    case largeTempFiles = "Temp & Scratch Files"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .unusedLargeFiles: return "clock.badge.exclamationmark.fill"
        case .duplicateFiles: return "doc.on.doc.fill"
        case .applicationCaches: return "memorychip.fill"
        case .developerArtifacts: return "wrench.and.screwdriver.fill"
        case .oldInstallers: return "opticaldiscdrive.fill"
        case .oldArchives: return "archivebox.fill"
        case .largeTempFiles: return "trash.circle.fill"
        }
    }
}

public enum CleanupSafetyRisk: String, Codable, Sendable {
    case low = "Safe to Remove"
    case moderate = "Review Before Removing"
    case high = "Keep Unless Certain"

    public var color: Color {
        switch self {
        case .low: return Color(red: 0.20, green: 0.82, blue: 0.64)
        case .moderate: return Color(red: 0.22, green: 0.68, blue: 0.96)
        case .high: return Color(red: 0.46, green: 0.54, blue: 0.66)
        }
    }
}

public struct CleanupCandidate: Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: CleanupKind
    public let title: String
    public let whatWillBeRemoved: String
    public let locationURL: URL
    public let sizeBytes: Int64
    public let lastUsedDate: Date?
    public let whyRecommended: String
    public let potentialConsequences: String
    public let risk: CleanupSafetyRisk
    public var isSelected: Bool

    public init(
        kind: CleanupKind,
        title: String,
        whatWillBeRemoved: String,
        locationURL: URL,
        sizeBytes: Int64,
        lastUsedDate: Date? = nil,
        whyRecommended: String,
        potentialConsequences: String,
        risk: CleanupSafetyRisk,
        isSelected: Bool = false
    ) {
        self.id = locationURL.path
        self.kind = kind
        self.title = title
        self.whatWillBeRemoved = whatWillBeRemoved
        self.locationURL = locationURL
        self.sizeBytes = sizeBytes
        self.lastUsedDate = lastUsedDate
        self.whyRecommended = whyRecommended
        self.potentialConsequences = potentialConsequences
        self.risk = risk
        self.isSelected = isSelected
    }
}

public struct CleanupExecutionResult: Sendable {
    public let movedToTrashCount: Int
    public let reclaimedBytes: Int64
    public let failures: [(path: String, reason: String)]

    public init(
        movedToTrashCount: Int,
        reclaimedBytes: Int64,
        failures: [(path: String, reason: String)]
    ) {
        self.movedToTrashCount = movedToTrashCount
        self.reclaimedBytes = reclaimedBytes
        self.failures = failures
    }
}

public struct ScanHistorySnapshot: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public let timestamp: Date
    public let scannedPath: String
    public let totalCapacityBytes: Int64
    public let usedBytes: Int64
    public let availableBytes: Int64
    public let scannedRootBytes: Int64
    public let categoryBreakdown: [String: Int64]
    public let topFolders: [String: Int64]

    public init(
        id: Int64 = 0,
        timestamp: Date,
        scannedPath: String,
        totalCapacityBytes: Int64,
        usedBytes: Int64,
        availableBytes: Int64,
        scannedRootBytes: Int64,
        categoryBreakdown: [String: Int64],
        topFolders: [String: Int64]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.scannedPath = scannedPath
        self.totalCapacityBytes = totalCapacityBytes
        self.usedBytes = usedBytes
        self.availableBytes = availableBytes
        self.scannedRootBytes = scannedRootBytes
        self.categoryBreakdown = categoryBreakdown
        self.topFolders = topFolders
    }
}

public struct StorageGrowthDelta: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let isFolder: Bool
    public let previousBytes: Int64
    public let currentBytes: Int64

    public var deltaBytes: Int64 { currentBytes - previousBytes }

    public var percentageChange: Double {
        guard previousBytes > 0 else { return 0 }
        return (Double(deltaBytes) / Double(previousBytes)) * 100.0
    }

    public init(name: String, isFolder: Bool, previousBytes: Int64, currentBytes: Int64) {
        self.id = "\(isFolder ? "folder" : "cat")-\(name)"
        self.name = name
        self.isFolder = isFolder
        self.previousBytes = previousBytes
        self.currentBytes = currentBytes
    }
}
