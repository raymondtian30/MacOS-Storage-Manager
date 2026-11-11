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
    // Navigation
    public var selectedSection: NavigationSection = .overview

    // Volume & Scan state
    public var volumeStats: VolumeStats = VolumeStats.currentBootVolume()
    public var selectedScanRoot: URL = FileManager.default.homeDirectoryForCurrentUser
    public var isScanning: Bool = false
    public var scanProgress: ScanProgress = ScanProgress()
    public var latestScanResult: ScanResult?
    public var analyzerCurrentNode: FileNode?
    public var analyzerBreadcrumbs: [FileNode] = []

    // Duplicate Finder state
    public var isFindingDuplicates: Bool = false
    public var duplicateProgress: (processed: Int, total: Int) = (0, 0)
    public var duplicateGroups: [DuplicateGroup] = []
    public var duplicateMinimumSizeMB: Double = 1.0

    // System Data state
    public var isAnalyzingSystemData: Bool = false
    public var systemDataReport: SystemDataReport?

    // Smart Cleanup state
    public var cleanupCandidates: [CleanupCandidate] = []
    public var lastCleanupResult: CleanupExecutionResult?

    // History state
    public var historySnapshots: [ScanHistorySnapshot] = []
    public var growthDeltas: [StorageGrowthDelta] = []

    // AI Assistant state
    public var aiMessages: [AIMessage] = [
        AIMessage(
            role: .assistant,
            content: "Welcome to **SpaceSense AI**. Run a storage scan or System Data analysis, then ask me why your disk is filling up, which folders have grown the most, or what is safe to move to Trash."
        )
    ]
    public var isAIThinking: Bool = false

    // Error & Banner notification state
    public var activeErrorMessage: String?
    public var statusBannerMessage: String?

    // Settings & Preferences (persisted in UserDefaults / Keychain)
    public var geminiModel: String {
        didSet { UserDefaults.standard.set(geminiModel, forKey: "spacesense.geminiModel") }
    }
    public var largeFileThresholdMB: Double {
        didSet { UserDefaults.standard.set(largeFileThresholdMB, forKey: "spacesense.largeFileThresholdMB") }
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

    public init(historyStore: HistoryStore = HistoryStore()) {
        self.historyStore = historyStore

        let defaults = UserDefaults.standard
        self.geminiModel = defaults.string(forKey: "spacesense.geminiModel") ?? "gemini-2.5-flash"
        let savedThreshold = defaults.double(forKey: "spacesense.largeFileThresholdMB")
        self.largeFileThresholdMB = savedThreshold > 0 ? savedThreshold : 50.0
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
        self.hasConfiguredAPIKey = (keychainService.loadAPIKey() != nil)
        self.historySnapshots = historyStore.fetchSnapshots()
        self.growthDeltas = historyStore.computeGrowthDeltas(snapshots: historySnapshots)

        // Start a lightweight System Data analysis in background on launch
        Task {
            await refreshSystemData()
        }
    }

    public func refreshVolumeStats() {
        volumeStats = VolumeStats.currentBootVolume()
    }

    public func chooseDirectoryAndScan() {
        if let chosen = bookmarkManager.promptForDirectory(initialURL: selectedScanRoot) {
            selectedScanRoot = chosen
            startScan(at: chosen)
        }
    }

    public func startScan(at url: URL? = nil) {
        let targetURL = url ?? selectedScanRoot
        selectedScanRoot = targetURL
        activeScanTask?.cancel()

        isScanning = true
        activeErrorMessage = nil
        statusBannerMessage = nil
        scanProgress = ScanProgress(currentPath: targetURL.path)

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
                        self?.scanProgress = progress
                    }
                }
                guard !Task.isCancelled else { return }

                self.latestScanResult = result
                self.volumeStats = result.volumeStats
                self.analyzerCurrentNode = result.rootNode
                self.analyzerBreadcrumbs = [result.rootNode]
                self.isScanning = false

                // Record in SQLite history
                _ = historyStore.recordScan(result, retentionDays: historyRetentionDays)
                self.historySnapshots = historyStore.fetchSnapshots()
                self.growthDeltas = historyStore.computeGrowthDeltas(snapshots: self.historySnapshots)

                // Refresh System Data, Duplicates, and Smart Cleanup recommendations
                await refreshSystemData()
                await runDuplicateScan()
                rebuildCleanupRecommendations()

                if enableScanNotifications {
                    postScanCompletedNotification(result: result)
                }
            } catch is CancellationError {
                self.isScanning = false
                self.statusBannerMessage = "Storage scan cancelled."
            } catch {
                self.isScanning = false
                self.activeErrorMessage = error.localizedDescription
            }
        }
    }

    public func cancelScan() {
        activeScanTask?.cancel()
        activeScanTask = nil
        isScanning = false
        statusBannerMessage = "Scan cancelled by user."
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

    // MARK: - Duplicate Finder

    public func runDuplicateScan() async {
        guard let scanResult = latestScanResult else { return }
        activeDuplicateTask?.cancel()
        isFindingDuplicates = true
        duplicateProgress = (0, 1)

        let minBytes = Int64(max(0.01, duplicateMinimumSizeMB) * 1024 * 1024)
        let files = scanResult.allFiles

        do {
            let groups = try await duplicateDetector.findDuplicates(
                in: files,
                minimumBytes: minBytes
            ) { [weak self] processed, total in
                Task { @MainActor [weak self] in
                    self?.duplicateProgress = (processed, total)
                }
            }
            self.duplicateGroups = groups
            self.isFindingDuplicates = false
            rebuildCleanupRecommendations()
        } catch {
            self.isFindingDuplicates = false
        }
    }

    public func toggleDuplicateSelection(groupID: String, fileID: String) {
        guard let gIdx = duplicateGroups.firstIndex(where: { $0.id == groupID }),
              let fIdx = duplicateGroups[gIdx].files.firstIndex(where: { $0.id == fileID }) else {
            return
        }
        let currentlyMarked = duplicateGroups[gIdx].files[fIdx].isMarkedForRemoval
        if !currentlyMarked {
            // Ensure at least one copy in the group remains unmarked so the user never deletes all copies accidentally
            let unmarkedCount = duplicateGroups[gIdx].files.filter { !$0.isMarkedForRemoval }.count
            if unmarkedCount <= 1 {
                statusBannerMessage = "At least one copy in each duplicate group is kept safe by default."
                return
            }
        }
        duplicateGroups[gIdx].files[fIdx].isMarkedForRemoval.toggle()
        rebuildCleanupRecommendations()
    }

    // MARK: - System Data & Smart Cleanup

    public func refreshSystemData() async {
        isAnalyzingSystemData = true
        refreshVolumeStats()
        let report = await systemDataAnalyzer.analyze(
            volumeStats: volumeStats,
            knownScanBytes: latestScanResult?.rootNode.size
        )
        self.systemDataReport = report
        self.isAnalyzingSystemData = false
        rebuildCleanupRecommendations()
    }

    public func rebuildCleanupRecommendations() {
        cleanupCandidates = cleanupEngine.buildRecommendations(
            scanResult: latestScanResult,
            systemDataReport: systemDataReport,
            duplicateGroups: duplicateGroups
        )
    }

    public var totalReclaimableBytes: Int64 {
        cleanupCandidates.reduce(0) { $0 + $1.sizeBytes }
    }

    public func moveURLsToTrash(_ urls: [URL], sizes: [URL: Int64] = [:]) async -> CleanupExecutionResult {
        let result = await cleanupEngine.moveItemsToTrash(urls: urls, itemSizes: sizes)
        lastCleanupResult = result
        refreshVolumeStats()

        // Remove trashed paths from in-memory lists immediately
        let trashedSet = Set(urls.map { $0.standardizedFileURL.path })
        cleanupCandidates.removeAll { trashedSet.contains($0.locationURL.standardizedFileURL.path) }

        for idx in duplicateGroups.indices {
            duplicateGroups[idx].files.removeAll { trashedSet.contains($0.url.standardizedFileURL.path) }
        }
        duplicateGroups.removeAll { $0.files.count < 2 }

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

    // MARK: - Gemini AI Assistant

    public func saveAPIKey(_ key: String) {
        _ = keychainService.saveAPIKey(key)
        hasConfiguredAPIKey = (keychainService.loadAPIKey() != nil)
    }

    public func removeAPIKey() {
        _ = keychainService.deleteAPIKey()
        hasConfiguredAPIKey = false
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
                model: geminiModel
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
