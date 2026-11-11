import Foundation
import SwiftUI
import AppKit
import Observation
import UserNotifications

public enum AppAppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case dark = "Dark"
    case light = "Light"
    case system = "System"

    public var id: String { rawValue }

    public var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}

@MainActor
@Observable
public final class AppState {
    public nonisolated static let currentVersion = "1.2.0"

    // Navigation
    public var selectedSection: NavigationSection = .overview

    // Volume & Scan state
    public var volumeStats: VolumeStats = VolumeStats.currentBootVolume()
    public var selectedScanRoot: URL = FileManager.default.homeDirectoryForCurrentUser
    public var isScanning: Bool = false
    public var showingStopScanPrompt: Bool = false
    public var scanProgress: ScanProgress = ScanProgress()
    public var latestScanResult: ScanResult?
    public var analyzerCurrentNode: FileNode?
    public var analyzerBreadcrumbs: [FileNode] = []
    public var analyzerCategoryFilter: StorageCategory?

    // Duplicate & Delete Hub state
    public var isFindingDuplicates: Bool = false
    public var isRefreshingCleanup: Bool = false
    public var duplicateProgress: (processed: Int, total: Int) = (0, 0)
    public var duplicateGroups: [DuplicateGroup] = []
    public var duplicateMinimumSizeMB: Double = 1.0
    public var cleanupCandidates: [CleanupCandidate] = []
    public var lastCleanupResult: CleanupExecutionResult?

    // System Data state
    public var isAnalyzingSystemData: Bool = false
    public var systemDataReport: SystemDataReport?

    // History state
    public var historySnapshots: [ScanHistorySnapshot] = []
    public var growthDeltas: [StorageGrowthDelta] = []

    // AI Assistant state
    public var aiMessages: [AIMessage] = [
        AIMessage(
            role: .assistant,
            content: "Welcome to **SpaceSense AI**. Run a storage scan, then ask me why your disk is filling up, which unused files are safe to remove in Delete Hub, or which folders have grown the most."
        )
    ]
    public var isAIThinking: Bool = false
    public var detectedAIProvider: AIProvider = .gemini
    public var detectedAIModels: [String] = AIProvider.gemini.defaultModels
    public var isDetectingModels: Bool = false

    // Updates state
    public var isCheckingForUpdates: Bool = false
    public var updateStatusMessage: String?
    public var availableUpdateURL: URL?

    // Error & Banner notification state
    public var activeErrorMessage: String?
    public var statusBannerMessage: String?

    // Settings & Preferences
    public var geminiModel: String {
        didSet { UserDefaults.standard.set(geminiModel, forKey: "spacesense.geminiModel") }
    }
    public var largeFileThresholdMB: Double {
        didSet {
            UserDefaults.standard.set(largeFileThresholdMB, forKey: "spacesense.largeFileThresholdMB")
            Task { await refreshCleanupRecommendationsAsync() }
        }
    }
    public var unusedFileDaysThreshold: Int {
        didSet {
            UserDefaults.standard.set(unusedFileDaysThreshold, forKey: "spacesense.unusedFileDaysThreshold")
            Task { await refreshCleanupRecommendationsAsync() }
        }
    }
    public var includeHiddenFiles: Bool {
        didSet { UserDefaults.standard.set(includeHiddenFiles, forKey: "spacesense.includeHiddenFiles") }
    }
    public var scanExclusions: [String] {
        didSet { UserDefaults.standard.set(scanExclusions, forKey: "spacesense.scanExclusions") }
    }
    public var historyRetentionDays: Int {
        didSet { UserDefaults.standard.set(historyRetentionDays, forKey: "spacesense.historyRetentionDays") }
    }
    public var appearanceMode: AppAppearanceMode {
        didSet { UserDefaults.standard.set(appearanceMode.rawValue, forKey: "spacesense.appearanceMode") }
    }
    public var enableScanNotifications: Bool {
        didSet { UserDefaults.standard.set(enableScanNotifications, forKey: "spacesense.enableScanNotifications") }
    }
    public var shareFullPathsWithAI: Bool {
        didSet { UserDefaults.standard.set(shareFullPathsWithAI, forKey: "spacesense.shareFullPathsWithAI") }
    }
    public var hasConfiguredAPIKey: Bool = false

    // Services
    public let scanner = StorageScanner()
    public let duplicateDetector = DuplicateDetector()
    public let systemDataAnalyzer = SystemDataAnalyzer()
    public let cleanupEngine = SmartCleanupEngine()
    public let historyStore: HistoryStore
    public let keychainService = KeychainService()
    public let geminiService = GeminiService()
    public let bookmarkManager = BookmarkManager()

    private var activeScanTask: Task<Void, Never>?
    private var activeDuplicateTask: Task<Void, Never>?
    private var activeCleanupTask: Task<Void, Never>?
    private var currentScanID: UUID = UUID()

    public nonisolated static let largeFileThresholdOptionsMB: [(label: String, value: Double)] = [
        ("250 MB", 250.0),
        ("500 MB", 500.0),
        ("750 MB", 750.0),
        ("1 GB", 1024.0)
    ]

    public nonisolated static let unusedDaysOptions: [(label: String, days: Int)] = [
        ("30 Days", 30),
        ("60 Days", 60),
        ("90 Days", 90),
        ("180 Days", 180),
        ("1 Year (365 Days)", 365)
    ]

    public init(historyStore: HistoryStore = HistoryStore()) {
        self.historyStore = historyStore

        let defaults = UserDefaults.standard
        self.geminiModel = defaults.string(forKey: "spacesense.geminiModel") ?? "gemini-2.5-flash"

        let savedThreshold = defaults.double(forKey: "spacesense.largeFileThresholdMB")
        let validThresholds: Set<Double> = [250.0, 500.0, 750.0, 1024.0]
        self.largeFileThresholdMB = validThresholds.contains(savedThreshold) ? savedThreshold : 250.0

        let savedUnusedDays = defaults.integer(forKey: "spacesense.unusedFileDaysThreshold")
        self.unusedFileDaysThreshold = savedUnusedDays > 0 ? savedUnusedDays : 90

        self.includeHiddenFiles = defaults.object(forKey: "spacesense.includeHiddenFiles") as? Bool ?? true
        self.scanExclusions = defaults.stringArray(forKey: "spacesense.scanExclusions") ?? [
            "/dev",
            "/System/Volumes/Data",
            "/System/Volumes/Preboot",
            "/System/Volumes/VM",
            "/System/Volumes/Update",
            "/Volumes"
        ]
        let savedRetention = defaults.integer(forKey: "spacesense.historyRetentionDays")
        self.historyRetentionDays = savedRetention > 0 ? savedRetention : 90
        let savedAppearance = defaults.string(forKey: "spacesense.appearanceMode") ?? AppAppearanceMode.dark.rawValue
        self.appearanceMode = AppAppearanceMode(rawValue: savedAppearance) ?? .dark
        self.enableScanNotifications = defaults.object(forKey: "spacesense.enableScanNotifications") as? Bool ?? false
        self.shareFullPathsWithAI = defaults.object(forKey: "spacesense.shareFullPathsWithAI") as? Bool ?? true

        _ = bookmarkManager.restoreSavedBookmarks()
        if let savedKey = keychainService.loadAPIKey() {
            self.hasConfiguredAPIKey = true
            let provider = AIProvider.detect(from: savedKey)
            self.detectedAIProvider = provider
            self.detectedAIModels = provider.defaultModels
            Task {
                await detectModelsForSavedKey(savedKey)
            }
        } else {
            self.hasConfiguredAPIKey = false
        }

        self.historySnapshots = historyStore.fetchSnapshots()
        self.growthDeltas = historyStore.computeGrowthDeltas(snapshots: historySnapshots)

        Task {
            await refreshSystemData()
        }
    }

    public func refreshVolumeStats() {
        volumeStats = VolumeStats.currentBootVolume()
    }

    /// Checks if a scan is already running before starting a new scan.
    /// If a scan is running, presents "Scan in progress, would you like to stop the scan?"
    public func requestStartScan(at url: URL? = nil) {
        if isScanning {
            showingStopScanPrompt = true
            return
        }
        startScan(at: url)
    }

    public func chooseDirectoryAndScan() {
        if isScanning {
            showingStopScanPrompt = true
            return
        }
        if let chosen = bookmarkManager.promptForDirectory(initialURL: selectedScanRoot) {
            selectedScanRoot = chosen
            startScan(at: chosen)
        }
    }

    public func startScan(at url: URL? = nil) {
        let targetURL = url ?? selectedScanRoot
        selectedScanRoot = targetURL
        activeScanTask?.cancel()

        let scanID = UUID()
        currentScanID = scanID
        isScanning = true
        activeErrorMessage = nil
        statusBannerMessage = nil
        scanProgress = ScanProgress(currentPath: targetURL.path, progressFraction: 0.02)

        let config = ScannerConfiguration(
            minimumLargeFileBytes: Int64(largeFileThresholdMB * 1024 * 1024),
            includeHiddenFiles: includeHiddenFiles,
            excludedPaths: Set(scanExclusions),
            maxTreeDepth: 6
        )

        activeScanTask = Task {
            do {
                let result = try await scanner.scan(rootURL: targetURL, configuration: config) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.currentScanID == scanID else { return }
                        self.scanProgress = progress
                    }
                }
                guard !Task.isCancelled, self.currentScanID == scanID else { return }

                self.latestScanResult = result
                self.volumeStats = result.volumeStats
                self.analyzerCurrentNode = result.rootNode
                self.analyzerBreadcrumbs = [result.rootNode]
                self.isScanning = false

                _ = historyStore.recordScan(result, retentionDays: historyRetentionDays)
                self.historySnapshots = historyStore.fetchSnapshots()
                self.growthDeltas = historyStore.computeGrowthDeltas(snapshots: self.historySnapshots)

                await refreshSystemData()
                await runDuplicateScan()
                await refreshCleanupRecommendationsAsync()

                if enableScanNotifications {
                    postScanCompletedNotification(result: result)
                }
            } catch is CancellationError {
                guard self.currentScanID == scanID else { return }
                self.isScanning = false
                self.statusBannerMessage = "Storage scan stopped."
            } catch {
                guard self.currentScanID == scanID else { return }
                self.isScanning = false
                self.activeErrorMessage = error.localizedDescription
            }
        }
    }

    public func cancelScan() {
        activeScanTask?.cancel()
        activeScanTask = nil
        isScanning = false
        showingStopScanPrompt = false
        statusBannerMessage = "Scan stopped."
    }

    // MARK: - Analyzer Navigation

    public func drillDown(to node: FileNode) {
        guard node.isDirectory else { return }
        analyzerCurrentNode = node
        if let existingIndex = analyzerBreadcrumbs.firstIndex(where: { $0.id == node.id }) {
            analyzerBreadcrumbs = Array(analyzerBreadcrumbs.prefix(through: existingIndex))
        } else {
            analyzerBreadcrumbs.append(node)
        }
    }

    public func navigateBack() {
        guard analyzerBreadcrumbs.count > 1 else { return }
        analyzerBreadcrumbs.removeLast()
        analyzerCurrentNode = analyzerBreadcrumbs.last
    }

    // MARK: - Duplicate Finder & Delete Hub

    public func runDuplicateScan() async {
        guard let scanResult = latestScanResult else { return }
        activeDuplicateTask?.cancel()
        isFindingDuplicates = true
        duplicateProgress = (0, 1)

        let minBytes = Int64(max(0.01, duplicateMinimumSizeMB) * 1024 * 1024)
        let files = scanResult.allFiles

        let task = Task { @MainActor in
            do {
                let groups = try await duplicateDetector.findDuplicates(
                    in: files,
                    minimumBytes: minBytes
                ) { [weak self] processed, total in
                    Task { @MainActor [weak self] in
                        self?.duplicateProgress = (processed, total)
                    }
                }
                guard !Task.isCancelled else { return }
                self.duplicateGroups = groups
                self.isFindingDuplicates = false
                await self.refreshCleanupRecommendationsAsync()
            } catch {
                self.isFindingDuplicates = false
            }
        }
        activeDuplicateTask = task
        await task.value
    }

    public func cancelDuplicateScan() {
        activeDuplicateTask?.cancel()
        activeDuplicateTask = nil
        isFindingDuplicates = false
    }

    public func toggleDuplicateSelection(groupID: String, fileID: String) {
        guard let gIdx = duplicateGroups.firstIndex(where: { $0.id == groupID }),
              let fIdx = duplicateGroups[gIdx].files.firstIndex(where: { $0.id == fileID }) else {
            return
        }
        let currentlyMarked = duplicateGroups[gIdx].files[fIdx].isMarkedForRemoval
        if !currentlyMarked {
            let unmarkedCount = duplicateGroups[gIdx].files.filter { !$0.isMarkedForRemoval }.count
            if unmarkedCount <= 1 {
                statusBannerMessage = "At least one copy in each duplicate group is kept safe by default."
                return
            }
        }
        duplicateGroups[gIdx].files[fIdx].isMarkedForRemoval.toggle()
        Task { await refreshCleanupRecommendationsAsync() }
    }

    // MARK: - System Data & Non-Blocking Cleanup Recommendations

    public func refreshSystemData() async {
        isAnalyzingSystemData = true
        refreshVolumeStats()
        let report = await systemDataAnalyzer.analyze(
            volumeStats: volumeStats,
            knownScanBytes: latestScanResult?.rootNode.size
        )
        self.systemDataReport = report
        self.isAnalyzingSystemData = false
        await refreshCleanupRecommendationsAsync()
    }

    public func rebuildCleanupRecommendations() {
        Task {
            await refreshCleanupRecommendationsAsync()
        }
    }

    /// Runs recommendation analysis on a background thread so the UI never freezes or shows a beachball.
    public func refreshCleanupRecommendationsAsync() async {
        activeCleanupTask?.cancel()
        isRefreshingCleanup = true

        let scanSnapshot = latestScanResult
        let sysSnapshot = systemDataReport
        let dupSnapshot = duplicateGroups
        let unusedDays = unusedFileDaysThreshold
        let thresholdBytes = Int64(largeFileThresholdMB * 1024 * 1024)
        let engine = cleanupEngine

        let task = Task.detached(priority: .userInitiated) { () -> [CleanupCandidate] in
            engine.buildRecommendations(
                scanResult: scanSnapshot,
                systemDataReport: sysSnapshot,
                duplicateGroups: dupSnapshot,
                unusedDaysThreshold: unusedDays,
                largeFileThresholdBytes: thresholdBytes
            )
        }

        let built = await task.value
        guard !Task.isCancelled else {
            isRefreshingCleanup = false
            return
        }
        self.cleanupCandidates = built
        self.isRefreshingCleanup = false
    }

    public var totalReclaimableBytes: Int64 {
        cleanupCandidates.reduce(0) { $0 + $1.sizeBytes }
    }

    public func moveURLsToTrash(_ urls: [URL], sizes: [URL: Int64] = [:]) async -> CleanupExecutionResult {
        let result = await cleanupEngine.moveItemsToTrash(urls: urls, itemSizes: sizes)
        lastCleanupResult = result
        refreshVolumeStats()

        let failedPaths = Set(result.failures.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        let trashedSet = Set(
            urls.map { $0.standardizedFileURL.path }
                .filter { !failedPaths.contains($0) }
        )

        cleanupCandidates.removeAll { trashedSet.contains($0.locationURL.standardizedFileURL.path) }

        for idx in duplicateGroups.indices {
            duplicateGroups[idx].files.removeAll { trashedSet.contains($0.url.standardizedFileURL.path) }
        }
        duplicateGroups.removeAll { $0.files.count < 2 }

        if let currentScan = latestScanResult, !trashedSet.isEmpty {
            let updatedLarge = currentScan.largeFiles.filter { !trashedSet.contains($0.url.standardizedFileURL.path) }
            let updatedAll = currentScan.allFiles.filter { !trashedSet.contains($0.url.standardizedFileURL.path) }
            latestScanResult = ScanResult(
                id: currentScan.id,
                timestamp: currentScan.timestamp,
                rootURL: currentScan.rootURL,
                durationSeconds: currentScan.durationSeconds,
                rootNode: currentScan.rootNode,
                categoryBytes: currentScan.categoryBytes,
                largeFiles: updatedLarge,
                allFiles: updatedAll,
                totalFilesScanned: currentScan.totalFilesScanned,
                totalDirectoriesScanned: currentScan.totalDirectoriesScanned,
                permissionErrorCount: currentScan.permissionErrorCount,
                volumeStats: volumeStats
            )
            if var node = analyzerCurrentNode {
                node.children.removeAll { trashedSet.contains($0.url.standardizedFileURL.path) }
                analyzerCurrentNode = node
            }
        }

        if result.movedToTrashCount > 0 {
            statusBannerMessage = "Moved \(result.movedToTrashCount) item(s) (\(ByteFormatting.string(result.reclaimedBytes))) to Trash."
        }
        if let firstFailure = result.failures.first {
            activeErrorMessage = "Could not move '\(firstFailure.path)' to Trash: \(firstFailure.reason)"
        }
        return result
    }

    // MARK: - Finder & Quick Actions

    public func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func openFile(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    // MARK: - Universal AI Key & Auto Model Detection

    public func saveAPIKey(_ key: String) {
        _ = keychainService.saveAPIKey(key)
        hasConfiguredAPIKey = (keychainService.loadAPIKey() != nil)
        Task {
            await detectModelsForSavedKey(key)
        }
    }

    public func detectModelsForSavedKey(_ key: String) async {
        isDetectingModels = true
        let detected = await geminiService.autoDetectProviderAndModels(for: key)
        detectedAIProvider = detected.provider
        detectedAIModels = detected.models
        if !detected.models.contains(geminiModel) {
            geminiModel = detected.recommendedModel
        }
        isDetectingModels = false
    }

    public func removeAPIKey() {
        _ = keychainService.deleteAPIKey()
        hasConfiguredAPIKey = false
        detectedAIProvider = .gemini
        detectedAIModels = AIProvider.gemini.defaultModels
    }

    public func currentAIContextSummary() -> String {
        geminiService.buildStorageContextSummary(
            volumeStats: volumeStats,
            scanResult: latestScanResult,
            systemDataReport: systemDataReport,
            duplicateGroups: duplicateGroups,
            cleanupCandidates: cleanupCandidates,
            growthDeltas: growthDeltas,
            shareFullPaths: shareFullPathsWithAI
        )
    }

    public func clearAIChat() {
        aiMessages = [
            AIMessage(
                role: .assistant,
                content: "Conversation cleared. Ask me any question about your latest storage scan, System Data, or Delete Hub recommendations."
            )
        ]
    }

    public func sendAIMessage(_ prompt: String) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAIThinking else { return }

        let historySnapshot = aiMessages
        aiMessages.append(AIMessage(role: .user, content: trimmed))
        isAIThinking = true

        guard let apiKey = keychainService.loadAPIKey() else {
            isAIThinking = false
            aiMessages.append(
                AIMessage(
                    role: .assistant,
                    content: GeminiError.missingAPIKey.localizedDescription,
                    isError: true
                )
            )
            return
        }

        let context = currentAIContextSummary()
        do {
            let reply = try await geminiService.askQuestion(
                question: trimmed,
                contextSummary: context,
                conversationHistory: historySnapshot,
                apiKey: apiKey,
                model: geminiModel,
                provider: detectedAIProvider
            )
            aiMessages.append(AIMessage(role: .assistant, content: reply))
        } catch {
            aiMessages.append(
                AIMessage(
                    role: .assistant,
                    content: error.localizedDescription,
                    isError: true
                )
            )
        }
        isAIThinking = false
    }

    // MARK: - Check for Updates

    public func checkForUpdates() async {
        isCheckingForUpdates = true
        updateStatusMessage = nil
        availableUpdateURL = nil

        guard let url = URL(string: "https://api.github.com/repos/raymondtian30/MacOS-Storage-Manager/releases/latest") else {
            isCheckingForUpdates = false
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                updateStatusMessage = "You are running SpaceSense v\(Self.currentVersion) (latest)."
                isCheckingForUpdates = false
                return
            }

            let normalizedRemote = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            let htmlURLString = json["html_url"] as? String ?? "https://github.com/raymondtian30/MacOS-Storage-Manager/releases"

            if normalizedRemote.compare(Self.currentVersion, options: .numeric) == .orderedDescending {
                updateStatusMessage = "Update available: \(tagName) (current: v\(Self.currentVersion))"
                availableUpdateURL = URL(string: htmlURLString)
            } else {
                updateStatusMessage = "SpaceSense v\(Self.currentVersion) is up to date."
            }
        } catch {
            updateStatusMessage = "Could not check GitHub Releases (\(error.localizedDescription)). Running v\(Self.currentVersion)."
        }

        isCheckingForUpdates = false
    }

    private func postScanCompletedNotification(result: ScanResult) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let bodyText = "Analyzed \(ByteFormatting.string(result.rootNode.size)) across \(result.totalFilesScanned) files."
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "SpaceSense Scan Complete"
            content.body = bodyText
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }
}
