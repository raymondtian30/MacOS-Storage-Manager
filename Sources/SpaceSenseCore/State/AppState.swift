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
    public nonisolated static let currentVersion = "1.2.2"

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
        didSet {
            let retention = historyRetentionDays
            UserDefaults.standard.set(retention, forKey: "spacesense.historyRetentionDays")
            let store = historyStore
            Task.detached(priority: .utility) { [weak self] in
                store.pruneOldSnapshots(retentionDays: retention)
                let snapshots = store.fetchSnapshots()
                let deltas = store.computeGrowthDeltas(snapshots: snapshots)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.historySnapshots = snapshots
                    self.growthDeltas = deltas
                }
            }
        }
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
    private var activeAITask: Task<Void, Never>?
    private var activeModelDetectTask: Task<Void, Never>?
    private var currentScanID: UUID = UUID()
    private var currentDuplicateID: UUID = UUID()
    private var currentCleanupID: UUID = UUID()

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
        let savedModel = defaults.string(forKey: "spacesense.geminiModel") ?? "gemini-2.5-flash"
        self.geminiModel = savedModel

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
            "/private/var/vm",
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
            if !provider.defaultModels.contains(self.geminiModel) {
                self.geminiModel = provider.defaultModels[0]
            }
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

                let store = self.historyStore
                let retention = self.historyRetentionDays
                Task.detached(priority: .utility) { [weak self] in
                    _ = store.recordScan(result, retentionDays: retention)
                    let snapshots = store.fetchSnapshots()
                    let deltas = store.computeGrowthDeltas(snapshots: snapshots)
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.historySnapshots = snapshots
                        self.growthDeltas = deltas
                    }
                }

                await refreshSystemData(useCachedProbes: true)
                await runDuplicateScan()

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

        let dupID = UUID()
        currentDuplicateID = dupID
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
                        guard let self, self.currentDuplicateID == dupID else { return }
                        self.duplicateProgress = (processed, total)
                    }
                }
                guard !Task.isCancelled, self.currentDuplicateID == dupID else { return }
                self.duplicateGroups = groups
                self.isFindingDuplicates = false
                await self.refreshCleanupRecommendationsAsync()
            } catch {
                guard self.currentDuplicateID == dupID else { return }
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

    public func refreshSystemData(useCachedProbes: Bool = false) async {
        isAnalyzingSystemData = true
        refreshVolumeStats()
        let premeasured = includeHiddenFiles ? (latestScanResult?.measuredDirectorySizes ?? [:]) : [:]
        let report = await systemDataAnalyzer.analyze(
            volumeStats: volumeStats,
            knownScanBytes: latestScanResult?.rootNode.size,
            premeasuredDirectorySizes: premeasured,
            useCachedProbes: useCachedProbes
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

    public func refreshCleanupRecommendationsAsync() async {
        activeCleanupTask?.cancel()
        let cleanupID = UUID()
        currentCleanupID = cleanupID
        isRefreshingCleanup = true

        let scanSnapshot = latestScanResult
        let sysSnapshot = systemDataReport
        let dupSnapshot = duplicateGroups
        let unusedDays = unusedFileDaysThreshold
        let thresholdBytes = Int64(largeFileThresholdMB * 1024 * 1024)
        let engine = cleanupEngine

        let wrapperTask = Task { @MainActor in
            let built = await Task.detached(priority: .userInitiated) { () -> [CleanupCandidate] in
                engine.buildRecommendations(
                    scanResult: scanSnapshot,
                    systemDataReport: sysSnapshot,
                    duplicateGroups: dupSnapshot,
                    unusedDaysThreshold: unusedDays,
                    largeFileThresholdBytes: thresholdBytes
                )
            }.value

            guard !Task.isCancelled, self.currentCleanupID == cleanupID else { return }
            self.cleanupCandidates = built
            self.isRefreshingCleanup = false
        }
        activeCleanupTask = wrapperTask
        await wrapperTask.value
    }

    public var totalReclaimableBytes: Int64 {
        cleanupCandidates.reduce(0) { $0 + $1.sizeBytes }
    }

    public func moveURLsToTrash(_ urls: [URL], sizes: [URL: Int64] = [:]) async -> CleanupExecutionResult {
        let result = await cleanupEngine.moveItemsToTrash(urls: urls, itemSizes: sizes)
        lastCleanupResult = result
        refreshVolumeStats()

        let failedPaths = Set(result.failures.map { StorageScanner.fastCleanPath(URL(fileURLWithPath: $0.path).standardizedFileURL.path) })
        let trashedSet = Set(
            urls.map { StorageScanner.fastCleanPath($0.standardizedFileURL.path) }
                .filter { !failedPaths.contains($0) }
        )

        cleanupCandidates.removeAll { Self.isPathOrDescendant(StorageScanner.fastCleanPath($0.locationURL.standardizedFileURL.path), in: trashedSet) }

        for idx in duplicateGroups.indices {
            duplicateGroups[idx].files.removeAll { Self.isPathOrDescendant(StorageScanner.fastCleanPath($0.url.standardizedFileURL.path), in: trashedSet) }
        }
        duplicateGroups.removeAll { $0.files.count < 2 }

        if let sysReport = systemDataReport, !trashedSet.isEmpty {
            var updatedSysItems: [SystemDataItem] = []
            var removedSysBytes: Int64 = 0
            for item in sysReport.items {
                let cleanedItemPath = StorageScanner.fastCleanPath(URL(fileURLWithPath: item.locationPath).standardizedFileURL.path)
                if Self.isPathOrDescendant(cleanedItemPath, in: trashedSet) {
                    removedSysBytes += item.sizeBytes ?? 0
                    updatedSysItems.append(
                        SystemDataItem(
                            category: item.category,
                            locationPath: item.locationPath,
                            url: item.url,
                            sizeBytes: 0,
                            measurability: item.measurability,
                            explanation: item.explanation,
                            recommendation: item.recommendation,
                            potentialRisks: item.potentialRisks,
                            isUserCleanable: false
                        )
                    )
                } else {
                    updatedSysItems.append(item)
                }
            }
            systemDataReport = SystemDataReport(
                timestamp: sysReport.timestamp,
                items: updatedSysItems,
                totalMeasuredBytes: max(0, sysReport.totalMeasuredBytes - removedSysBytes),
                estimatedUnindexedSystemBytes: sysReport.estimatedUnindexedSystemBytes,
                inaccessiblePathCount: sysReport.inaccessiblePathCount
            )
        }

        if let currentScan = latestScanResult, !trashedSet.isEmpty {
            var updatedCategories = currentScan.categoryBytes
            var updatedAll: [LargeFileItem] = []
            updatedAll.reserveCapacity(currentScan.allFiles.count)
            var trashedCount = 0

            for file in currentScan.allFiles {
                if Self.isPathOrDescendant(StorageScanner.fastCleanPath(file.path), in: trashedSet) {
                    updatedCategories[file.category] = max(0, (updatedCategories[file.category] ?? 0) - file.size)
                    trashedCount += 1
                } else {
                    updatedAll.append(file)
                }
            }

            let updatedLarge = currentScan.largeFiles.filter { !Self.isPathOrDescendant(StorageScanner.fastCleanPath($0.path), in: trashedSet) }
            let updatedRoot = Self.pruneTree(node: currentScan.rootNode, trashedPaths: trashedSet).node

            latestScanResult = ScanResult(
                id: currentScan.id,
                timestamp: currentScan.timestamp,
                rootURL: currentScan.rootURL,
                durationSeconds: currentScan.durationSeconds,
                rootNode: updatedRoot,
                categoryBytes: updatedCategories,
                largeFiles: updatedLarge,
                allFiles: updatedAll,
                totalFilesScanned: max(0, currentScan.totalFilesScanned - trashedCount),
                totalDirectoriesScanned: currentScan.totalDirectoriesScanned,
                permissionErrorCount: currentScan.permissionErrorCount,
                volumeStats: volumeStats,
                measuredDirectorySizes: currentScan.measuredDirectorySizes
            )

            // Re-sync breadcrumbs and current analyzer node from the updated tree
            analyzerBreadcrumbs = analyzerBreadcrumbs.compactMap { crumb in
                Self.findNode(id: crumb.id, in: updatedRoot)
            }
            if analyzerBreadcrumbs.isEmpty {
                analyzerBreadcrumbs = [updatedRoot]
            }
            analyzerCurrentNode = analyzerBreadcrumbs.last
        }

        await refreshCleanupRecommendationsAsync()

        if result.movedToTrashCount > 0 {
            statusBannerMessage = "Moved \(result.movedToTrashCount) item(s) (\(ByteFormatting.string(result.reclaimedBytes))) to Trash."
        }
        if let firstFailure = result.failures.first {
            activeErrorMessage = "Could not move '\(firstFailure.path)' to Trash: \(firstFailure.reason)"
        }
        return result
    }

    private static func isPathOrDescendant(_ path: String, in trashedPaths: Set<String>) -> Bool {
        if trashedPaths.contains(path) { return true }
        return trashedPaths.contains { path.hasPrefix($0 + "/") }
    }

    private static func pruneTree(node: FileNode, trashedPaths: Set<String>) -> (node: FileNode, removedBytes: Int64, removedCount: Int) {
        var totalRemovedBytes: Int64 = 0
        var totalRemovedCount = 0
        var keptChildren: [FileNode] = []

        for child in node.children {
            let childPath = StorageScanner.fastCleanPath(child.url.standardizedFileURL.path)
            if isPathOrDescendant(childPath, in: trashedPaths) {
                totalRemovedBytes += child.size
                totalRemovedCount += max(1, child.itemCount)
            } else if child.isDirectory {
                let prunedChild = pruneTree(node: child, trashedPaths: trashedPaths)
                totalRemovedBytes += prunedChild.removedBytes
                totalRemovedCount += prunedChild.removedCount
                keptChildren.append(prunedChild.node)
            } else {
                keptChildren.append(child)
            }
        }

        let updatedNode = FileNode(
            url: node.url,
            name: node.name,
            isDirectory: node.isDirectory,
            size: max(0, node.size - totalRemovedBytes),
            modificationDate: node.modificationDate,
            fileExtension: node.fileExtension,
            category: node.category,
            itemCount: max(0, node.itemCount - totalRemovedCount),
            isAccessible: node.isAccessible,
            children: keptChildren
        )
        return (updatedNode, totalRemovedBytes, totalRemovedCount)
    }

    private static func findNode(id: String, in root: FileNode) -> FileNode? {
        if root.id == id { return root }
        for child in root.children where child.isDirectory {
            if let found = findNode(id: id, in: child) {
                return found
            }
        }
        return nil
    }

    // MARK: - Finder & Quick Actions

    public func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func openFile(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    public func copyPathToClipboard(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        statusBannerMessage = "Copied path to clipboard."
    }

    // MARK: - Universal AI Key & Auto Model Detection

    public func saveAPIKey(_ key: String) {
        activeModelDetectTask?.cancel()
        let saved = keychainService.saveAPIKey(key)
        hasConfiguredAPIKey = (keychainService.loadAPIKey() != nil)
        if !saved {
            activeErrorMessage = "Could not save API key to macOS Keychain."
            return
        }
        let provider = AIProvider.detect(from: key)
        detectedAIProvider = provider
        detectedAIModels = provider.defaultModels
        if !provider.defaultModels.contains(geminiModel) {
            geminiModel = provider.defaultModels[0]
        }
        activeModelDetectTask = Task {
            await detectModelsForSavedKey(key)
        }
    }

    public func detectModelsForSavedKey(_ key: String) async {
        isDetectingModels = true
        let detected = await geminiService.autoDetectProviderAndModels(for: key)
        guard !Task.isCancelled else {
            isDetectingModels = false
            return
        }
        detectedAIProvider = detected.provider
        detectedAIModels = detected.models
        if !detected.models.contains(geminiModel) {
            geminiModel = detected.recommendedModel
        }
        isDetectingModels = false
    }

    public func removeAPIKey() {
        activeModelDetectTask?.cancel()
        isDetectingModels = false
        _ = keychainService.deleteAPIKey()
        hasConfiguredAPIKey = false
        detectedAIProvider = .gemini
        detectedAIModels = AIProvider.gemini.defaultModels
        geminiModel = AIProvider.gemini.defaultModels[0]
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
        activeAITask?.cancel()
        activeAITask = nil
        isAIThinking = false
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
        let model = geminiModel
        let provider = detectedAIProvider

        let task = Task { @MainActor in
            do {
                let reply = try await geminiService.askQuestion(
                    question: trimmed,
                    contextSummary: context,
                    conversationHistory: historySnapshot,
                    apiKey: apiKey,
                    model: model,
                    provider: provider
                )
                guard !Task.isCancelled else { return }
                aiMessages.append(AIMessage(role: .assistant, content: reply))
            } catch {
                guard !Task.isCancelled else { return }
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
        activeAITask = task
        await task.value
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

            let htmlURLString = json["html_url"] as? String ?? "https://github.com/raymondtian30/MacOS-Storage-Manager/releases"

            if Self.isRemoteVersionNewer(remoteTag: tagName, currentVersion: Self.currentVersion) {
                updateStatusMessage = "Update available: \(tagName) (current: v\(Self.currentVersion))"
                if let parsedURL = URL(string: htmlURLString), parsedURL.scheme == "https" {
                    availableUpdateURL = parsedURL
                }
            } else {
                updateStatusMessage = "SpaceSense v\(Self.currentVersion) is up to date."
            }
        } catch {
            updateStatusMessage = "Could not check GitHub Releases (\(error.localizedDescription)). Running v\(Self.currentVersion)."
        }

        isCheckingForUpdates = false
    }

    private static func isRemoteVersionNewer(remoteTag: String, currentVersion: String) -> Bool {
        let cleanRemote = remoteTag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: "-").first.map(String.init) ?? ""
        let cleanCurrent = currentVersion.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: "-").first.map(String.init) ?? ""
        let rParts = cleanRemote.split(separator: ".").compactMap { Int($0) }
        let cParts = cleanCurrent.split(separator: ".").compactMap { Int($0) }
        let count = max(rParts.count, cParts.count)
        for i in 0..<count {
            let r = i < rParts.count ? rParts[i] : 0
            let c = i < cParts.count ? cParts[i] : 0
            if r != c { return r > c }
        }
        return false
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
