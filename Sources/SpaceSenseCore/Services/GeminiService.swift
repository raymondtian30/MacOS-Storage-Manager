import Foundation

public enum AIProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case gemini = "Google Gemini"
    case openai = "OpenAI"
    case anthropic = "Anthropic Claude"
    case groq = "Groq"
    case xai = "xAI (Grok)"
    case openRouter = "OpenRouter"

    public var id: String { rawValue }

    public var defaultModels: [String] {
        switch self {
        case .gemini:
            return ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.0-flash"]
        case .openai:
            return ["gpt-4o-mini", "gpt-4o", "o3-mini"]
        case .anthropic:
            return ["claude-3-7-sonnet-latest", "claude-3-5-haiku-latest", "claude-3-5-sonnet-latest"]
        case .groq:
            return ["llama-3.3-70b-versatile", "llama-3.1-8b-instant", "mixtral-8x7b-32768"]
        case .xai:
            return ["grok-2-latest", "grok-beta"]
        case .openRouter:
            return ["openai/gpt-4o-mini", "anthropic/claude-3.5-sonnet", "google/gemini-2.0-flash-001"]
        }
    }

    public static func detect(from apiKey: String) -> AIProvider {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("AIza") {
            return .gemini
        }
        if trimmed.hasPrefix("sk-ant-") {
            return .anthropic
        }
        if trimmed.hasPrefix("gsk_") {
            return .groq
        }
        if trimmed.hasPrefix("xai-") {
            return .xai
        }
        if trimmed.hasPrefix("sk-or-") {
            return .openRouter
        }
        if trimmed.hasPrefix("sk-") {
            return .openai
        }
        return .gemini
    }
}

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
            return "No AI API key is configured. Open Settings to add any supported API key (Gemini, OpenAI, Anthropic, Groq, xAI, or OpenRouter)."
        case .invalidAPIKey:
            return "The configured API key was rejected (HTTP 401/403). Please verify your key in Settings."
        case .rateLimited:
            return "AI provider rate limit reached (HTTP 429). Please wait a moment and try again."
        case .serverError(let code, let detail):
            return "AI API returned HTTP \(code): \(detail)"
        case .emptyResponse:
            return "The AI model returned an empty response. Try rephrasing your question."
        case .networkError(let msg):
            return "Network error while contacting AI provider: \(msg)"
        }
    }
}

public struct GeminiService: Sendable {
    public static var availableModels: [String] {
        AIProvider.gemini.defaultModels
    }

    public init() {}

    /// Automatically detects the AI provider from the key and queries the provider's live `/models` endpoint
    /// to discover available chat models for that specific API key.
    public func autoDetectProviderAndModels(for apiKey: String) async -> (provider: AIProvider, models: [String], recommendedModel: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = AIProvider.detect(from: trimmed)
        let defaults = provider.defaultModels
        guard !trimmed.isEmpty else {
            return (provider, defaults, defaults[0])
        }

        if let liveModels = await fetchLiveModels(provider: provider, apiKey: trimmed), !liveModels.isEmpty {
            // Merge defaults that exist in liveModels first so recommended models are never truncated out
            var prioritized: [String] = []
            for def in defaults where liveModels.contains(def) {
                prioritized.append(def)
            }
            for model in liveModels where !prioritized.contains(model) {
                prioritized.append(model)
            }
            let capped = Array(prioritized.prefix(20))
            let preferred = pickRecommendedModel(for: provider, from: capped)
            return (provider, capped, preferred)
        }

        return (provider, defaults, defaults[0])
    }

    private func fetchLiveModels(provider: AIProvider, apiKey: String) async -> [String]? {
        let urlString: String
        var headers: [String: String] = [:]

        switch provider {
        case .gemini:
            urlString = "https://generativelanguage.googleapis.com/v1beta/models"
            headers["x-goog-api-key"] = apiKey
        case .openai:
            urlString = "https://api.openai.com/v1/models"
            headers["Authorization"] = "Bearer \(apiKey)"
        case .anthropic:
            urlString = "https://api.anthropic.com/v1/models"
            headers["x-api-key"] = apiKey
            headers["anthropic-version"] = "2023-06-01"
        case .groq:
            urlString = "https://api.groq.com/openai/v1/models"
            headers["Authorization"] = "Bearer \(apiKey)"
        case .xai:
            urlString = "https://api.x.ai/v1/models"
            headers["Authorization"] = "Bearer \(apiKey)"
        case .openRouter:
            urlString = "https://openrouter.ai/api/v1/models"
            headers["Authorization"] = "Bearer \(apiKey)"
        }

        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 6
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if provider == .gemini, let modelsArray = json["models"] as? [[String: Any]] {
            let names: [String] = modelsArray.compactMap { entry in
                guard let rawName = entry["name"] as? String else { return nil }
                let methods = entry["supportedGenerationMethods"] as? [String] ?? []
                guard methods.contains("generateContent") else { return nil }
                let shortName = rawName.replacingOccurrences(of: "models/", with: "")
                guard shortName.hasPrefix("gemini-") &&
                      !shortName.contains("embedding") &&
                      !shortName.contains("imagen") &&
                      !shortName.contains("aqa") else {
                    return nil
                }
                return shortName
            }
            return names.isEmpty ? nil : names
        }

        if let dataArray = json["data"] as? [[String: Any]] {
            let excludedSubstrings = [
                "embed", "whisper", "tts", "dall-e", "moderation",
                "instruct", "realtime", "audio", "davinci", "babbage",
                "transcribe", "image", "computer-use", "search"
            ]
            let ids: [String] = dataArray.compactMap { entry in
                guard let id = entry["id"] as? String else { return nil }
                let lower = id.lowercased()
                if excludedSubstrings.contains(where: { lower.contains($0) }) {
                    return nil
                }
                return id
            }
            return ids.isEmpty ? nil : ids
        }

        return nil
    }

    private func pickRecommendedModel(for provider: AIProvider, from available: [String]) -> String {
        for preferred in provider.defaultModels {
            if let exact = available.first(where: { $0 == preferred }) {
                return exact
            }
        }
        for preferred in provider.defaultModels {
            if let prefixMatch = available.first(where: { $0.hasPrefix(preferred) }) {
                return prefixMatch
            }
        }
        return available.first ?? provider.defaultModels[0]
    }

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
        lines.append("Volume: \(volumeStats.volumeName)")
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
                lines.append("- \(formatPath(file.path, shareFullPaths: shareFullPaths)): \(ByteFormatting.string(file.size)) [Last opened: \(file.daysSinceLastOpened())d ago, Category: \(file.category.rawValue)]")
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
        lines.append("\n--- DELETE HUB (DUPLICATES, UNUSED LARGE FILES & SAFE CLEANUP) ---")
        lines.append("Exact SHA-256 Duplicate Groups: \(duplicateGroups.count) (\(ByteFormatting.string(totalDupReclaimable)) potentially reclaimable)")
        let totalCleanupBytes = cleanupCandidates.reduce(0) { $0 + $1.sizeBytes }
        lines.append("Delete Hub Candidates: \(cleanupCandidates.count) items totaling \(ByteFormatting.string(totalCleanupBytes))")
        for candidate in cleanupCandidates.prefix(10) {
            let safePath = formatPath(candidate.locationURL.path, shareFullPaths: shareFullPaths)
            lines.append("- [\(candidate.kind.rawValue)] \(safePath): \(ByteFormatting.string(candidate.sizeBytes)) (\(candidate.risk.rawValue))")
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
        model: String = "gemini-2.5-flash",
        provider: AIProvider? = nil
    ) async throws -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw GeminiError.missingAPIKey
        }

        let activeProvider = provider ?? AIProvider.detect(from: trimmedKey)

        let systemInstruction = """
        You are SpaceSense AI, an expert macOS storage advisor built into the native SpaceSense macOS app.
        STRICT RULES:
        1. Base every answer strictly on the ACTUAL MAC STORAGE TELEMETRY provided below.
        2. Never invent file paths, folder names, or byte measurements that are not in the telemetry.
        3. Clearly distinguish MEASURED storage values from ESTIMATED values (such as APFS snapshots or unindexed system data) and RESTRICTED/inaccessible locations.
        4. Explain findings in clear, practical, everyday language for a Mac user.
        5. Never recommend deleting macOS System Integrity Protection (SIP) files, /System, /usr, /bin, or active Application Support databases without warning about consequences.
        6. Always recommend moving unneeded user files or caches to Trash via SpaceSense's Delete Hub review flow rather than running destructive terminal commands.

        \(contextSummary)
        """

        let sanitizedHistory = normalizeAlternatingHistory(from: conversationHistory)

        switch activeProvider {
        case .gemini:
            return try await callGeminiAPI(
                question: question,
                systemInstruction: systemInstruction,
                conversationHistory: sanitizedHistory,
                apiKey: trimmedKey,
                model: model
            )
        case .anthropic:
            return try await callAnthropicAPI(
                question: question,
                systemInstruction: systemInstruction,
                conversationHistory: sanitizedHistory,
                apiKey: trimmedKey,
                model: model
            )
        case .openai, .groq, .xai, .openRouter:
            return try await callOpenAICompatibleAPI(
                provider: activeProvider,
                question: question,
                systemInstruction: systemInstruction,
                conversationHistory: sanitizedHistory,
                apiKey: trimmedKey,
                model: model
            )
        }
    }

    /// Ensures conversation history starts with `.user`, ends with `.assistant`, and strictly alternates roles.
    private func normalizeAlternatingHistory(from history: [AIMessage]) -> [AIMessage] {
        let nonError = history.suffix(8).filter { !$0.isError }
        let userStarted = nonError.drop(while: { $0.role != .user })
        var result: [AIMessage] = []
        for msg in userStarted {
            if let last = result.last, last.role == msg.role {
                result[result.count - 1] = msg
            } else {
                result.append(msg)
            }
        }
        if result.last?.role == .user {
            result.removeLast()
        }
        return result
    }

    private func callGeminiAPI(
        question: String,
        systemInstruction: String,
        conversationHistory: [AIMessage],
        apiKey: String,
        model: String
    ) async throws -> String {
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "gemini-2.5-flash"
        guard let endpointURL = URL(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent"
        ) else {
            throw GeminiError.invalidAPIKey
        }

        var contentsArray: [[String: Any]] = []
        for msg in conversationHistory {
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
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, _) = try await performRequest(request)
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

    private func callAnthropicAPI(
        question: String,
        systemInstruction: String,
        conversationHistory: [AIMessage],
        apiKey: String,
        model: String
    ) async throws -> String {
        guard let endpointURL = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw GeminiError.invalidAPIKey
        }

        var messages: [[String: String]] = []
        for msg in conversationHistory {
            messages.append([
                "role": msg.role == .user ? "user" : "assistant",
                "content": msg.content
            ])
        }
        messages.append(["role": "user", "content": question])

        let requestBody: [String: Any] = [
            "model": model,
            "max_tokens": 1200,
            "system": systemInstruction,
            "messages": messages
        ]

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, _) = try await performRequest(request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.compactMap({ $0["text"] as? String }).first,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiError.emptyResponse
        }
        return text
    }

    private func callOpenAICompatibleAPI(
        provider: AIProvider,
        question: String,
        systemInstruction: String,
        conversationHistory: [AIMessage],
        apiKey: String,
        model: String
    ) async throws -> String {
        let urlString: String
        switch provider {
        case .openai, .gemini, .anthropic:
            urlString = "https://api.openai.com/v1/chat/completions"
        case .groq:
            urlString = "https://api.groq.com/openai/v1/chat/completions"
        case .xai:
            urlString = "https://api.x.ai/v1/chat/completions"
        case .openRouter:
            urlString = "https://openrouter.ai/api/v1/chat/completions"
        }

        guard let endpointURL = URL(string: urlString) else {
            throw GeminiError.invalidAPIKey
        }

        var messages: [[String: String]] = [
            ["role": "system", "content": systemInstruction]
        ]
        for msg in conversationHistory {
            messages.append([
                "role": msg.role == .user ? "user" : "assistant",
                "content": msg.content
            ])
        }
        messages.append(["role": "user", "content": question])

        let lowerModel = model.lowercased()
        let isReasoningModel = lowerModel.hasPrefix("o1") || lowerModel.hasPrefix("o3") || lowerModel.hasPrefix("o4")

        var requestBody: [String: Any] = [
            "model": model,
            "messages": messages
        ]
        if !isReasoningModel {
            requestBody["temperature"] = 0.2
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, _) = try await performRequest(request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let text = message["content"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiError.emptyResponse
        }
        return text
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
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
            return (data, httpResponse)
        case 401, 403:
            throw GeminiError.invalidAPIKey
        case 429:
            throw GeminiError.rateLimited
        default:
            let bodyText = String(data: data, encoding: .utf8) ?? "Unknown error"
            if httpResponse.statusCode == 400 && bodyText.contains("API_KEY_INVALID") {
                throw GeminiError.invalidAPIKey
            }
            throw GeminiError.serverError(httpResponse.statusCode, String(bodyText.prefix(200)))
        }
    }

    public func formatPath(_ path: String, shareFullPaths: Bool) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var normalized = path
        if normalized == home {
            normalized = "~"
        } else if normalized.hasPrefix(home + "/") {
            normalized = "~" + normalized.dropFirst(home.count)
        }
        if shareFullPaths {
            return normalized
        }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
        guard let last = components.last else { return normalized }
        if normalized.hasPrefix("~/") {
            return "~/.../\(last)"
        }
        return "/.../\(last)"
    }
}
