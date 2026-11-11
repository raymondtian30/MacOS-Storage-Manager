import Foundation

public enum SelfTestRunner {
    private struct TestFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw TestFailure(message: message)
        }
    }

    public static func runAllTests() async -> Bool {
        print("=== SpaceSense Automated Verification Suite ===")
        var passed = 0
        var failed = 0

        let suites: [(String, () async throws -> Void)] = [
            ("1. Volume Telemetry & 9-Section Navigation", testVolumeAndNavigation),
            ("2. Storage Category Classification", testStorageCategoryClassification),
            ("3. Filesystem Scanner, Folder Sizes & Symlink Loop Protection", testScannerAndSymlinks),
            ("4. CryptoKit SHA-256 Duplicate Detection & Safety", testCryptoKitDuplicates),
            ("5. System Data Analyzer (Measured vs. Estimated vs. Restricted)", testSystemDataAnalyzer),
            ("6. Smart Cleanup Recommendations & SIP Path Protection", testSmartCleanupAndTrash),
            ("7. SQLite HistoryStore Persistence & Growth Deltas", testSQLiteHistoryStore),
            ("8. macOS Keychain & Gemini Telemetry Builder / Error Handling", testKeychainAndGemini)
        ]

        for (name, block) in suites {
            do {
                try await block()
                passed += 1
                print("  [PASS] \(name)")
            } catch {
                failed += 1
                print("  [FAIL] \(name): \(error)")
            }
        }

        print("=== Summary: \(passed)/\(suites.count) passed, \(failed) failed ===")
        return failed == 0
    }

    private static func makeTempDir() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("SpaceSenseSelfTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func testVolumeAndNavigation() async throws {
        let stats = VolumeStats.currentBootVolume()
        try expect(stats.totalBytes > 0, "Expected positive boot volume total capacity")
        try expect(stats.usedBytes >= 0, "Expected non-negative used storage")
        try expect(stats.availableBytes >= 0, "Expected non-negative available storage")
        try expect(NavigationSection.allCases.count == 9, "Expected all 9 required navigation sections")
        try expect(AppAppearanceMode.dark.colorScheme == .dark, "Expected dark scheme")
        try expect(AppAppearanceMode.light.colorScheme == .light, "Expected light scheme")
    }

    private static func testStorageCategoryClassification() async throws {
        try expect(
            StorageCategory.classify(url: URL(fileURLWithPath: "/Applications/Safari.app"), isDirectory: true) == .applications,
            "Expected /Applications/Safari.app to classify as .applications"
        )
        try expect(
            StorageCategory.classify(url: URL(fileURLWithPath: "/Users/demo/Downloads/archive.dmg")) == .downloads,
            "Expected Downloads file to classify as .downloads"
        )
        try expect(
            StorageCategory.classify(url: URL(fileURLWithPath: "/Users/demo/Documents/spec.pdf")) == .documents,
            "Expected PDF in Documents to classify as .documents"
        )
        try expect(
            StorageCategory.classify(url: URL(fileURLWithPath: "/Users/demo/Pictures/img.heic")) == .photosAndMedia,
            "Expected HEIC in Pictures to classify as .photosAndMedia"
        )
        try expect(
            StorageCategory.classify(url: URL(fileURLWithPath: "/Users/demo/Developer/App/main.swift")) == .developer,
            "Expected Swift source file to classify as .developer"
        )
        try expect(
            StorageCategory.classify(url: URL(fileURLWithPath: "/Users/demo/Library/Caches/cache.db")) == .systemData,
            "Expected Library/Caches file to classify as .systemData"
        )
    }

    private static func testScannerAndSymlinks() async throws {
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

        // Create recursive symlink loop pointing back to tempRoot
        let symlinkURL = docsDir.appendingPathComponent("symlink_loop")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: tempRoot)

        let scanner = StorageScanner()
        let config = ScannerConfiguration(
            minimumLargeFileBytes: 200_000,
            includeHiddenFiles: true,
            excludedPaths: [],
            maxTreeDepth: 5
        )
        let result = try await scanner.scan(rootURL: tempRoot, configuration: config)
        try expect(result.totalFilesScanned == 2, "Expected 2 regular files scanned without following symlink loop")
        try expect(result.rootNode.size >= 400_000, "Expected folder size >= 400 KB")
        try expect(result.largeFiles.count == 1 && result.largeFiles.first?.name == "clip.mov", "Expected clip.mov detected as large file")
        let cached = await scanner.cachedDirectorySize(for: tempRoot.standardizedFileURL.path)
        try expect(cached != nil, "Expected directory summary cache to be populated")
    }

    private static func testCryptoKitDuplicates() async throws {
        let tempRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let folder1 = tempRoot.appendingPathComponent("A", isDirectory: true)
        let folder2 = tempRoot.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: folder1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder2, withIntermediateDirectories: true)

        let payload = Data((0..<90_000).map { UInt8($0 % 251) })
        let dup1 = folder1.appendingPathComponent("first_name.dat")
        let dup2 = folder2.appendingPathComponent("different_name.dat")
        try payload.write(to: dup1)
        try payload.write(to: dup2)

        let diffPayload = Data((0..<90_000).map { UInt8(($0 + 13) % 251) })
        let nonDup = folder2.appendingPathComponent("first_name.dat")
        try diffPayload.write(to: nonDup)

        let items = [
            LargeFileItem(url: dup1, size: Int64(payload.count), modificationDate: Date(timeIntervalSinceNow: -60)),
            LargeFileItem(url: dup2, size: Int64(payload.count), modificationDate: Date()),
            LargeFileItem(url: nonDup, size: Int64(diffPayload.count), modificationDate: Date())
        ]

        let detector = DuplicateDetector()
        let groups = try await detector.findDuplicates(in: items, minimumBytes: 1024)
        try expect(groups.count == 1, "Expected exactly 1 duplicate group")
        let group = groups[0]
        try expect(group.files.count == 2, "Expected 2 identical files in duplicate group")
        try expect(group.files.filter { !$0.isMarkedForRemoval }.count == 1, "Expected 1 original copy kept unmarked")
        try expect(group.files.filter { $0.isMarkedForRemoval }.count == 1, "Expected 1 duplicate copy marked for removal")
    }

    private static func testSystemDataAnalyzer() async throws {
        let tempHome = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let cachesDir = tempHome.appendingPathComponent("Library/Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: cachesDir, withIntermediateDirectories: true)
        try Data(repeating: 0xAA, count: 64_000).write(to: cachesDir.appendingPathComponent("sample.cache"))

        let analyzer = SystemDataAnalyzer()
        let vol = VolumeStats.currentBootVolume()
        let report = await analyzer.analyze(
            volumeStats: vol,
            knownScanBytes: 1_000_000,
            customHomeURL: tempHome,
            maxFilesPerLocation: 500
        )
        try expect(!report.items.isEmpty, "Expected System Data items")
        try expect(report.items.contains { $0.measurability == .measured }, "Expected measured System Data entries")
        try expect(report.items.contains { $0.measurability == .estimated }, "Expected estimated System Data entry")
        try expect(report.items.contains { $0.measurability == .restricted }, "Expected restricted System Data entry")
        try expect(report.totalMeasuredBytes >= 32_000, "Expected measured cache bytes >= 32 KB")
    }

    private static func testSmartCleanupAndTrash() async throws {
        let tempRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try expect(SmartCleanupEngine.isProtectedSystemPath("/System/Library"), "Expected /System/Library to be protected")
        try expect(SmartCleanupEngine.isProtectedSystemPath("/usr/bin"), "Expected /usr/bin to be protected")
        try expect(!SmartCleanupEngine.isProtectedSystemPath(tempRoot.path), "Expected temp dir to be non-protected")

        let downloads = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let dmgFile = downloads.appendingPathComponent("OldInstaller.dmg")
        try Data(repeating: 0x33, count: 11 * 1024 * 1024).write(to: dmgFile)

        let scanner = StorageScanner()
        let scan = try await scanner.scan(
            rootURL: tempRoot,
            configuration: ScannerConfiguration(minimumLargeFileBytes: 1024, excludedPaths: [])
        )

        let engine = SmartCleanupEngine()
        let recs = engine.buildRecommendations(scanResult: scan, systemDataReport: nil, duplicateGroups: [])
        try expect(recs.count == 1, "Expected 1 installer cleanup recommendation")
        let rec = recs[0]
        try expect(!rec.whatWillBeRemoved.isEmpty && !rec.whyRecommended.isEmpty && !rec.potentialConsequences.isEmpty, "Expected all 5 safety fields populated")

        // Verify moving protected path is blocked
        let blocked = await engine.moveItemsToTrash(urls: [URL(fileURLWithPath: "/System/Library")])
        try expect(blocked.movedToTrashCount == 0 && blocked.failures.count == 1, "Expected protected path deletion to be rejected")
    }

    private static func testSQLiteHistoryStore() async throws {
        let tempRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let dbURL = tempRoot.appendingPathComponent("history_test.sqlite")
        let store = HistoryStore(customDatabaseURL: dbURL)
        let vol = VolumeStats(volumeName: "Macintosh HD", mountPoint: "/", totalBytes: 500_000_000_000, availableBytes: 200_000_000_000, usedBytes: 300_000_000_000)

        let node1 = FileNode(url: tempRoot, isDirectory: true, size: 100_000_000)
        let scan1 = ScanResult(
            timestamp: Date(timeIntervalSinceNow: -120),
            rootURL: tempRoot,
            durationSeconds: 0.1,
            rootNode: node1,
            categoryBytes: [.developer: 100_000_000],
            largeFiles: [],
            allFiles: [],
            totalFilesScanned: 5,
            totalDirectoriesScanned: 1,
            permissionErrorCount: 0,
            volumeStats: vol
        )

        let node2 = FileNode(url: tempRoot, isDirectory: true, size: 180_000_000)
        let scan2 = ScanResult(
            timestamp: Date(),
            rootURL: tempRoot,
            durationSeconds: 0.1,
            rootNode: node2,
            categoryBytes: [.developer: 180_000_000],
            largeFiles: [],
            allFiles: [],
            totalFilesScanned: 8,
            totalDirectoriesScanned: 1,
            permissionErrorCount: 0,
            volumeStats: vol
        )

        try expect(store.recordScan(scan1) != nil, "Expected first scan recorded in SQLite")
        try expect(store.recordScan(scan2) != nil, "Expected second scan recorded in SQLite")
        let snaps = store.fetchSnapshots()
        try expect(snaps.count == 2, "Expected 2 snapshots fetched from SQLite")
        let deltas = store.computeGrowthDeltas(snapshots: snaps)
        try expect(deltas.first?.deltaBytes == 80_000_000, "Expected +80 MB growth delta")
    }

    private static func testKeychainAndGemini() async throws {
        let keychain = KeychainService(service: "com.spacesense.selftest.\(UUID().uuidString)", account: "gemini")
        defer { keychain.deleteAPIKey() }

        try expect(keychain.loadAPIKey() == nil, "Expected empty initial keychain")
        try expect(keychain.saveAPIKey("AIzaTestKey999"), "Expected saving API key to succeed")
        try expect(keychain.loadAPIKey() == "AIzaTestKey999", "Expected loading saved API key to match")
        try expect(keychain.deleteAPIKey(), "Expected deleting API key to succeed")
        try expect(keychain.loadAPIKey() == nil, "Expected keychain to be nil after deletion")

        let gemini = GeminiService()
        let summary = gemini.buildStorageContextSummary(
            volumeStats: VolumeStats.currentBootVolume(),
            scanResult: nil,
            systemDataReport: nil,
            duplicateGroups: [],
            cleanupCandidates: [],
            growthDeltas: [],
            shareFullPaths: false
        )
        try expect(summary.contains("ACTUAL MAC STORAGE TELEMETRY"), "Expected telemetry header in Gemini context")

        var caughtMissingKey = false
        do {
            _ = try await gemini.askQuestion(
                question: "Test?",
                contextSummary: summary,
                conversationHistory: [],
                apiKey: ""
            )
        } catch GeminiError.missingAPIKey {
            caughtMissingKey = true
        }
        try expect(caughtMissingKey, "Expected GeminiError.missingAPIKey when key is empty")
    }
}
