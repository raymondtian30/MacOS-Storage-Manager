import Foundation
import Testing
@testable import SpaceSenseCore

@Suite("SpaceSense Core Verification Suite")
struct SpaceSenseTests {
    private func makeTempDir() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("SpaceSenseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Volume telemetry and navigation sections")
    func volumeStatsAndNavigationSections() {
        let stats = VolumeStats.currentBootVolume()
        #expect(stats.totalBytes > 0)
        #expect(stats.usedBytes >= 0)
        #expect(stats.availableBytes >= 0)
        #expect(NavigationSection.allCases.count == 9)
        #expect(AppAppearanceMode.dark.colorScheme == .dark)
        #expect(AppAppearanceMode.light.colorScheme == .light)
        #expect(AppAppearanceMode.system.colorScheme == nil)
    }

    @Test("Storage category classification")
    func storageCategoryClassification() {
        #expect(StorageCategory.classify(url: URL(fileURLWithPath: "/Applications/Xcode.app"), isDirectory: true) == .applications)
        #expect(StorageCategory.classify(url: URL(fileURLWithPath: "/Users/test/Downloads/installer.dmg")) == .downloads)
        #expect(StorageCategory.classify(url: URL(fileURLWithPath: "/Users/test/Documents/report.pdf")) == .documents)
        #expect(StorageCategory.classify(url: URL(fileURLWithPath: "/Users/test/Pictures/photo.heic")) == .photosAndMedia)
        #expect(StorageCategory.classify(url: URL(fileURLWithPath: "/Users/test/Developer/Project/main.swift")) == .developer)
        #expect(StorageCategory.classify(url: URL(fileURLWithPath: "/Users/test/Library/Caches/com.apple.Safari/cache.db")) == .systemData)
    }

    @Test("Filesystem scanning, folder size calculation, and symlink loop protection")
    func filesystemScanningAndSymlinkProtection() async throws {
        let tempRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let docsDir = tempRoot.appendingPathComponent("Documents", isDirectory: true)
        let mediaDir = tempRoot.appendingPathComponent("Pictures", isDirectory: true)
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        let fileA = docsDir.appendingPathComponent("manual.pdf")
        let fileB = mediaDir.appendingPathComponent("clip.mov")
        try Data(repeating: 0x41, count: 120_000).write(to: fileA)
        try Data(repeating: 0x42, count: 350_000).write(to: fileB)

        // Create recursive symbolic link pointing back to tempRoot
        let symlinkURL = docsDir.appendingPathComponent("recursive_loop_link")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: tempRoot)

        let scanner = StorageScanner()
        let config = ScannerConfiguration(
            minimumLargeFileBytes: 200_000,
            includeHiddenFiles: true,
            excludedPaths: [],
            maxTreeDepth: 5
        )

        let result = try await scanner.scan(rootURL: tempRoot, configuration: config)
        #expect(result.totalFilesScanned == 2)
        #expect(result.rootNode.size >= 400_000)
        #expect(result.largeFiles.count == 1)
        #expect(result.largeFiles.first?.name == "clip.mov")

        let cachedSize = await scanner.cachedDirectorySize(for: tempRoot.standardizedFileURL.path)
        #expect(cachedSize != nil)
    }

    @Test("CryptoKit SHA-256 duplicate detection")
    func cryptoKitDuplicateDetection() async throws {
        let tempRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let folder1 = tempRoot.appendingPathComponent("Folder1", isDirectory: true)
        let folder2 = tempRoot.appendingPathComponent("Folder2", isDirectory: true)
        try FileManager.default.createDirectory(at: folder1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder2, withIntermediateDirectories: true)

        let sharedPayload = Data((0..<90_000).map { UInt8($0 % 251) })
        let dup1 = folder1.appendingPathComponent("alpha_original.bin")
        let dup2 = folder2.appendingPathComponent("beta_copy.bin")
        try sharedPayload.write(to: dup1)
        try sharedPayload.write(to: dup2)

        let differentPayload = Data((0..<90_000).map { UInt8(($0 + 7) % 251) })
        let nonDup = folder2.appendingPathComponent("alpha_original.bin")
        try differentPayload.write(to: nonDup)

        let candidates = [
            LargeFileItem(url: dup1, size: Int64(sharedPayload.count), modificationDate: Date(timeIntervalSinceNow: -100)),
            LargeFileItem(url: dup2, size: Int64(sharedPayload.count), modificationDate: Date()),
            LargeFileItem(url: nonDup, size: Int64(differentPayload.count), modificationDate: Date())
        ]

        let detector = DuplicateDetector()
        let groups = try await detector.findDuplicates(in: candidates, minimumBytes: 1024)
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group.files.count == 2)
        #expect(group.reclaimableBytes == Int64(sharedPayload.count))
        #expect(group.files.filter { !$0.isMarkedForRemoval }.count == 1)
        #expect(group.files.filter { $0.isMarkedForRemoval }.count == 1)
    }

    @Test("System Data analysis distinguishes measured, estimated, and restricted paths")
    func systemDataAnalysis() async {
        let analyzer = SystemDataAnalyzer()
        let volume = VolumeStats.currentBootVolume()
        let report = await analyzer.analyze(volumeStats: volume, knownScanBytes: 1_000_000)

        #expect(!report.items.isEmpty)
        #expect(report.items.contains { $0.measurability == .measured })
        #expect(report.items.contains { $0.measurability == .estimated })
        #expect(report.items.contains { $0.measurability == .restricted })
    }

    @Test("Smart Cleanup safety and SIP path protection")
    func smartCleanupSafety() async throws {
        let tempRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        #expect(SmartCleanupEngine.isProtectedSystemPath("/System/Library/CoreServices"))
        #expect(SmartCleanupEngine.isProtectedSystemPath("/usr/bin"))
        #expect(SmartCleanupEngine.isProtectedSystemPath("/bin/sh"))
        #expect(SmartCleanupEngine.isProtectedSystemPath("/"))
        #expect(!SmartCleanupEngine.isProtectedSystemPath(tempRoot.path))

        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        let fakeInstaller = downloadsDir.appendingPathComponent("SampleApp.dmg")
        try Data(repeating: 0x5A, count: 11 * 1024 * 1024).write(to: fakeInstaller)

        let scanner = StorageScanner()
        let scanResult = try await scanner.scan(
            rootURL: tempRoot,
            configuration: ScannerConfiguration(minimumLargeFileBytes: 1024, excludedPaths: [])
        )

        let engine = SmartCleanupEngine()
        let recommendations = engine.buildRecommendations(
            scanResult: scanResult,
            systemDataReport: nil,
            duplicateGroups: []
        )

        #expect(recommendations.count == 1)
        let rec = try #require(recommendations.first)
        #expect(rec.kind == .oldInstallers)
        #expect(!rec.whatWillBeRemoved.isEmpty)
        #expect(!rec.whyRecommended.isEmpty)
        #expect(!rec.potentialConsequences.isEmpty)
        #expect(rec.sizeBytes > 0)

        let protectedAttempt = await engine.moveItemsToTrash(urls: [URL(fileURLWithPath: "/System/Library")])
        #expect(protectedAttempt.movedToTrashCount == 0)
        #expect(protectedAttempt.failures.count == 1)
    }

    @Test("SQLite HistoryStore persistence and growth delta calculations")
    func sqliteHistoryStore() throws {
        let tempRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let dbURL = tempRoot.appendingPathComponent("test_history.sqlite")
        let store = HistoryStore(customDatabaseURL: dbURL)

        let vol = VolumeStats(
            volumeName: "TestDisk",
            mountPoint: "/",
            totalBytes: 500_000_000_000,
            availableBytes: 200_000_000_000,
            usedBytes: 300_000_000_000
        )

        let child1 = FileNode(url: tempRoot.appendingPathComponent("Projects"), isDirectory: true, size: 100_000_000)
        let root1 = FileNode(url: tempRoot, isDirectory: true, size: 100_000_000, children: [child1])
        let scan1 = ScanResult(
            timestamp: Date(timeIntervalSinceNow: -3600),
            rootURL: tempRoot,
            durationSeconds: 0.5,
            rootNode: root1,
            categoryBytes: [.developer: 100_000_000, .documents: 50_000_000],
            largeFiles: [],
            allFiles: [],
            totalFilesScanned: 10,
            totalDirectoriesScanned: 2,
            permissionErrorCount: 0,
            volumeStats: vol
        )

        let child2 = FileNode(url: tempRoot.appendingPathComponent("Projects"), isDirectory: true, size: 250_000_000)
        let root2 = FileNode(url: tempRoot, isDirectory: true, size: 250_000_000, children: [child2])
        let scan2 = ScanResult(
            timestamp: Date(),
            rootURL: tempRoot,
            durationSeconds: 0.5,
            rootNode: root2,
            categoryBytes: [.developer: 250_000_000, .documents: 50_000_000],
            largeFiles: [],
            allFiles: [],
            totalFilesScanned: 15,
            totalDirectoriesScanned: 2,
            permissionErrorCount: 0,
            volumeStats: vol
        )

        #expect(store.recordScan(scan1) != nil)
        #expect(store.recordScan(scan2) != nil)

        let snapshots = store.fetchSnapshots()
        #expect(snapshots.count == 2)

        let deltas = store.computeGrowthDeltas(snapshots: snapshots)
        #expect(!deltas.isEmpty)
        #expect(deltas.contains { $0.deltaBytes == 150_000_000 })
    }

    @Test("Keychain credential storage and Gemini context builder")
    func keychainAndGeminiContext() async {
        let testKeychain = KeychainService(
            service: "com.spacesense.tests.\(UUID().uuidString)",
            account: "test_gemini_key"
        )
        defer { testKeychain.deleteAPIKey() }

        #expect(testKeychain.loadAPIKey() == nil)
        #expect(testKeychain.saveAPIKey("AIzaSyTestKey12345"))
        #expect(testKeychain.loadAPIKey() == "AIzaSyTestKey12345")
        #expect(testKeychain.deleteAPIKey())
        #expect(testKeychain.loadAPIKey() == nil)

        let gemini = GeminiService()
        let vol = VolumeStats.currentBootVolume()
        let summary = gemini.buildStorageContextSummary(
            volumeStats: vol,
            scanResult: nil,
            systemDataReport: nil,
            duplicateGroups: [],
            cleanupCandidates: [],
            growthDeltas: [],
            shareFullPaths: false
        )
        #expect(summary.contains("ACTUAL MAC STORAGE TELEMETRY"))
        #expect(summary.contains(vol.volumeName))
    }
}
