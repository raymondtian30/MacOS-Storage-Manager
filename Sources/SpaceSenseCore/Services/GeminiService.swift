import Foundation

public struct AIMessage: Identifiable, Equatable, Sendable {
    public enum Role: String, Sendable {
        case user
        case assistant
    }

    public let id: UUID
    public let role: Role
    public let content: String
    public let timestamp: Date
    public let isError: Bool

    public init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        timestamp: Date = Date(),
        isError: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isError = isError
    }
}

public enum GeminiError: LocalizedError, Sendable {
    case missingAPIKey
    case invalidAPIKey
    case rateLimited
    case serverError(Int, String)
    case emptyResponse
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Gemini API key is not configured. Open Settings to add your API key securely to the macOS Keychain."
        case .invalidAPIKey:
            return "The configured Gemini API key was rejected (HTTP 400/401/403). Please verify your key in Settings."
        case .rateLimited:
            return "Gemini API rate limit reached (HTTP 429). Please wait a moment and try again."
        case .serverError(let code, let detail):
            return "Gemini API returned HTTP \(code): \(detail)"
        case .emptyResponse:
            return "Gemini returned an empty response. Try rephrasing your question."
        case .networkError(let msg):
            return "Network error while contacting Gemini: \(msg)"
        }
    }
}

public struct GeminiService: Sendable {
    public static let availableModels: [String] = [
        "gemini-2.5-flash",
        "gemini-2.5-pro",
        "gemini-2.0-flash"
    ]

    public init() {}

    /// Builds a structured, privacy-safe summary of actual scan measurements without ever including file contents.
    public func buildStorageContextSummary(
        volumeStats: VolumeStats,
        scanResult: ScanResult?,
        systemDataReport: SystemDataReport?,
        duplicateGroups: [DuplicateGroup],
        cleanupCandidates: [CleanupCandidate],
        growthDeltas: [StorageGrowthDelta],
        shareFullPaths: Bool
    ) -> String {
        var lines: [String] = []
        lines.append("=== ACTUAL MAC STORAGE TELEMETRY (MEASURED BY SPACESENSE) ===")
        lines.append("Volume: \(volumeStats.volumeName) (\(volumeStats.mountPoint))")
        lines.append("Total Capacity: \(ByteFormatting.string(volumeStats.totalBytes))")
        lines.append("Used Storage: \(ByteFormatting.string(volumeStats.usedBytes)) (\(String(format: "%.1f%%", volumeStats.utilizationPercentage)))")
        lines.append("Available Storage: \(ByteFormatting.string(volumeStats.availableBytes))")

        if let scan = scanResult {
            lines.append("\n--- LAST DIRECTORY SCAN ---")
            lines.append("Scanned Root: \(formatPath(scan.rootURL.path, shareFullPaths: shareFullPaths))")
            lines.append("Scan Time: \(scan.timestamp.formatted(date: .abbreviated, time: .shortened))")
            lines.append("Total Measured in Root: \(ByteFormatting.string(scan.rootNode.size)) across \(scan.totalFilesScanned) files and \(scan.totalDirectoriesScanned) folders")
            if scan.permissionErrorCount > 0 {
                lines.append("Inaccessible/Permission-Restricted Items Encountered: \(scan.permissionErrorCount)")
            }

            lines.append("\n--- CATEGORY BREAKDOWN (MEASURED) ---")
            for cat in StorageCategory.allCases {
                let bytes = scan.categoryBytes[cat] ?? 0
                lines.append("- \(cat.rawValue): \(ByteFormatting.string(bytes))")
            }

            lines.append("\n--- TOP FOLDERS IN SCANNED ROOT (MEASURED) ---")
            for child in scan.rootNode.children.prefix(12) {
                lines.append("- \(formatPath(child.url.path, shareFullPaths: shareFullPaths)): \(ByteFormatting.string(child.size)) (\(child.itemCount) items)")
            }

            lines.append("\n--- LARGEST INDIVIDUAL FILES (TOP 12 MEASURED) ---")
            for file in scan.largeFiles.prefix(12) {
                lines.append("- \(formatPath(file.path, shareFullPaths: shareFullPaths)): \(ByteFormatting.string(file.size)) [Category: \(file.category.rawValue)]")
            }
        } else {
            lines.append("\n--- DIRECTORY SCAN STATUS ---")
            lines.append("No user directory scan has been run yet in this session; only volume-level capacity is currently measured.")
        }

        if let sys = systemDataReport {
            lines.append("\n--- SYSTEM DATA ANALYSIS ---")
            lines.append("Total Directly Measured System Data: \(ByteFormatting.string(sys.totalMeasuredBytes))")
            lines.append("Estimated Unindexed/Snapshot System Data: \(ByteFormatting.string(sys.estimatedUnindexedSystemBytes)) (ESTIMATE based on volume used minus measured files)")
            lines.append("Permission-Restricted System Paths: \(sys.inaccessiblePathCount)")
            for item in sys.items.prefix(10) {
                let sizeLabel = item.sizeBytes.map { ByteFormatting.string($0) } ?? "Inaccessible"
                lines.append("- \(item.category) [\(item.measurability.rawValue)]: \(sizeLabel) | Recommendation: \(item.recommendation.rawValue) | Path: \(formatPath(item.locationPath, shareFullPaths: shareFullPaths))")
            }
        }

        let totalDupReclaimable = duplicateGroups.reduce(0) { $0 + $1.reclaimableBytes }
        lines.append("\n--- DUPLICATES & SMART CLEANUP ---")
        lines.append("Exact SHA-256 Duplicate Groups: \(duplicateGroups.count) (\(ByteFormatting.string(totalDupReclaimable)) potentially reclaimable)")
        let totalCleanupBytes = cleanupCandidates.reduce(0) { $0 + $1.sizeBytes }
        lines.append("Smart Cleanup Candidates: \(cleanupCandidates.count) items totaling \(ByteFormatting.string(totalCleanupBytes))")
        for candidate in cleanupCandidates.prefix(8) {
            lines.append("- [\(candidate.kind.rawValue)] \(candidate.title): \(ByteFormatting.string(candidate.sizeBytes)) (\(candidate.risk.rawValue))")
        }

        if !growthDeltas.isEmpty {
            lines.append("\n--- HISTORICAL STORAGE GROWTH DELTAS (LATEST VS PREVIOUS SCAN) ---")
            for delta in growthDeltas.prefix(8) {
                let sign = delta.deltaBytes >= 0 ? "+" : ""
                let label = delta.isFolder ? formatPath(delta.name, shareFullPaths: shareFullPaths) : delta.name
                lines.append("- \(label): \(sign)\(ByteFormatting.string(delta.deltaBytes)) (now \(ByteFormatting.string(delta.currentBytes)))")
            }
        }

        return lines.joined(separator: "\n")
    }

    public func askQuestion(
        question: String,
        contextSummary: String,
        conversationHistory: [AIMessage],
        apiKey: String,
        model: String = "gemini-2.5-flash"
    ) async throws -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw GeminiError.missingAPIKey
        }

        let systemInstruction = """
        You are SpaceSense AI, an expert macOS storage advisor built into the native SpaceSense macOS app.
        STRICT RULES:
        1. Base every answer strictly on the ACTUAL MAC STORAGE TELEMETRY provided below.
        2. Never invent file paths, folder names, or byte measurements that are not in the telemetry.
        3. Clearly distinguish MEASURED storage values from ESTIMATED values (such as APFS snapshots or unindexed system data) and RESTRICTED/inaccessible locations.
        4. Explain findings in clear, practical, everyday language for a Mac user.
        5. Never recommend deleting macOS System Integrity Protection (SIP) files, /System, /usr, /bin, or active Application Support databases without warning about consequences.
        6. Always recommend moving unneeded user files or caches to Trash via SpaceSense's review flow rather than running destructive terminal commands.

        \(contextSummary)
        """

        guard let endpointURL = URL(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(trimmedKey)"
        ) else {
            throw GeminiError.invalidAPIKey
        }

        var contentsArray: [[String: Any]] = []
        for msg in conversationHistory.suffix(6) where !msg.isError {
            let role = msg.role == .user ? "user" : "model"
            contentsArray.append([
                "role": role,
                "parts": [["text": msg.content]]
            ])
        }
        contentsArray.append([
            "role": "user",
            "parts": [["text": question]]
        ])

        let requestBody: [String: Any] = [
            "system_instruction": [
                "parts": [["text": systemInstruction]]
            ],
            "contents": contentsArray,
            "generationConfig": [
                "temperature": 0.2,
                "maxOutputTokens": 1200
            ]
        ]

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw GeminiError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiError.networkError("Invalid server response.")
        }

        switch httpResponse.statusCode {
        case 200...299:
            break
        case 400, 401, 403:
            throw GeminiError.invalidAPIKey
        case 429:
            throw GeminiError.rateLimited
        default:
            let bodyText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GeminiError.serverError(httpResponse.statusCode, String(bodyText.prefix(200)))
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.compactMap({ $0["text"] as? String }).first,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiError.emptyResponse
        }

        return text
    }

    private func formatPath(_ path: String, shareFullPaths: Bool) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var normalized = path
        if normalized.hasPrefix(home) {
            normalized = "~" + normalized.dropFirst(home.count)
        }
        if shareFullPaths {
            return normalized
        }
        // Redact intermediate user-specific folder names if privacy mode is strict
        let components = normalized.split(separator: "/")
        if components.count <= 3 {
            return normalized
        }
        return ".../" + components.suffix(2).joined(separator: "/")
    }
}
