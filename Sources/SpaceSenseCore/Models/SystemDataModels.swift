import Foundation
import SwiftUI

public enum MeasurabilityType: String, Codable, Sendable {
    case measured = "Measured"
    case estimated = "Estimated"
    case restricted = "Restricted / Inaccessible"

    public var badgeColor: Color {
        switch self {
        case .measured: return Color(red: 0.20, green: 0.82, blue: 0.64)
        case .estimated: return Color(red: 0.22, green: 0.68, blue: 0.96)
        case .restricted: return Color(red: 0.46, green: 0.54, blue: 0.66)
        }
    }
}

public enum CleanupRecommendationLevel: String, Codable, Sendable {
    case recommended = "Safe to Clean"
    case reviewCarefully = "Review Before Cleaning"
    case doNotModify = "Do Not Modify"

    public var color: Color {
        switch self {
        case .recommended: return Color(red: 0.20, green: 0.82, blue: 0.64)
        case .reviewCarefully: return Color(red: 0.22, green: 0.68, blue: 0.96)
        case .doNotModify: return Color(red: 0.46, green: 0.54, blue: 0.66)
        }
    }
}

public struct SystemDataItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let category: String
    public let locationPath: String
    public let url: URL?
    public let sizeBytes: Int64?
    public let measurability: MeasurabilityType
    public let explanation: String
    public let recommendation: CleanupRecommendationLevel
    public let potentialRisks: String
    public let isUserCleanable: Bool

    public init(
        category: String,
        locationPath: String,
        url: URL? = nil,
        sizeBytes: Int64?,
        measurability: MeasurabilityType,
        explanation: String,
        recommendation: CleanupRecommendationLevel,
        potentialRisks: String,
        isUserCleanable: Bool
    ) {
        self.id = "\(category)-\(locationPath)"
        self.category = category
        self.locationPath = locationPath
        self.url = url
        self.sizeBytes = sizeBytes
        self.measurability = measurability
        self.explanation = explanation
        self.recommendation = recommendation
        self.potentialRisks = potentialRisks
        self.isUserCleanable = isUserCleanable
    }
}

public struct SystemDataReport: Sendable {
    public let timestamp: Date
    public let items: [SystemDataItem]
    public let totalMeasuredBytes: Int64
    public let estimatedUnindexedSystemBytes: Int64
    public let inaccessiblePathCount: Int

    public init(
        timestamp: Date = Date(),
        items: [SystemDataItem],
        totalMeasuredBytes: Int64,
        estimatedUnindexedSystemBytes: Int64,
        inaccessiblePathCount: Int
    ) {
        self.timestamp = timestamp
        self.items = items
        self.totalMeasuredBytes = totalMeasuredBytes
        self.estimatedUnindexedSystemBytes = estimatedUnindexedSystemBytes
        self.inaccessiblePathCount = inaccessiblePathCount
    }

    public var cleanableBytes: Int64 {
        items
            .filter { $0.recommendation == .recommended && $0.measurability == .measured }
            .compactMap(\.sizeBytes)
            .reduce(0, +)
    }
}
