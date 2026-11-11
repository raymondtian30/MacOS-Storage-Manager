import Foundation
import SQLite3

public final class HistoryStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    public let databasePath: String

    public init(customDatabaseURL: URL? = nil) {
        let fileURL: URL
        if let customDatabaseURL {
            fileURL = customDatabaseURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let folder = appSupport.appendingPathComponent("SpaceSense", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            fileURL = folder.appendingPathComponent("storage_history.sqlite")
        }
        self.databasePath = fileURL.path
        openDatabase()
        createTablesIfNeeded()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    private func openDatabase() {
        lock.lock()
        defer { lock.unlock() }
        if sqlite3_open(databasePath, &db) != SQLITE_OK {
            if let db {
                sqlite3_close(db)
            }
            db = nil
        }
    }

    private func createTablesIfNeeded() {
        let sql = """
        CREATE TABLE IF NOT EXISTS scan_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp REAL NOT NULL,
            scanned_path TEXT NOT NULL,
            total_capacity_bytes INTEGER NOT NULL,
            used_bytes INTEGER NOT NULL,
            available_bytes INTEGER NOT NULL,
            scanned_root_bytes INTEGER NOT NULL,
            category_json TEXT NOT NULL,
            folders_json TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_snapshots_timestamp ON scan_snapshots(timestamp DESC);
        """
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    @discardableResult
    public func recordScan(_ result: ScanResult, retentionDays: Int = 90) -> ScanHistorySnapshot? {
        var categoryMap: [String: Int64] = [:]
        for (cat, bytes) in result.categoryBytes {
            categoryMap[cat.rawValue] = bytes
        }

        var topFoldersMap: [String: Int64] = [:]
        for child in result.rootNode.children.filter(\.isDirectory).prefix(15) {
            topFoldersMap[child.url.path] = child.size
        }

        let encoder = JSONEncoder()
        let categoryJSON = (try? String(data: encoder.encode(categoryMap), encoding: .utf8)) ?? "{}"
        let foldersJSON = (try? String(data: encoder.encode(topFoldersMap), encoding: .utf8)) ?? "{}"

        let insertSQL = """
        INSERT INTO scan_snapshots (
            timestamp, scanned_path, total_capacity_bytes, used_bytes, available_bytes,
            scanned_root_bytes, category_json, folders_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """

        lock.lock()
        defer { lock.unlock() }
        guard let db else { return nil }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        let ts = result.timestamp.timeIntervalSince1970
        let path = result.rootURL.path
        let sqlTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        sqlite3_bind_double(stmt, 1, ts)
        sqlite3_bind_text(stmt, 2, path, -1, sqlTransient)
        sqlite3_bind_int64(stmt, 3, result.volumeStats.totalBytes)
        sqlite3_bind_int64(stmt, 4, result.volumeStats.usedBytes)
        sqlite3_bind_int64(stmt, 5, result.volumeStats.availableBytes)
        sqlite3_bind_int64(stmt, 6, result.rootNode.size)
        sqlite3_bind_text(stmt, 7, categoryJSON, -1, sqlTransient)
        sqlite3_bind_text(stmt, 8, foldersJSON, -1, sqlTransient)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            return nil
        }

        let rowID = sqlite3_last_insert_rowid(db)
        pruneOldSnapshotsUnlocked(retentionDays: retentionDays)

        return ScanHistorySnapshot(
            id: rowID,
            timestamp: result.timestamp,
            scannedPath: path,
            totalCapacityBytes: result.volumeStats.totalBytes,
            usedBytes: result.volumeStats.usedBytes,
            availableBytes: result.volumeStats.availableBytes,
            scannedRootBytes: result.rootNode.size,
            categoryBreakdown: categoryMap,
            topFolders: topFoldersMap
        )
    }

    public func fetchSnapshots(limit: Int = 100) -> [ScanHistorySnapshot] {
        let querySQL = """
        SELECT id, timestamp, scanned_path, total_capacity_bytes, used_bytes, available_bytes,
               scanned_root_bytes, category_json, folders_json
        FROM scan_snapshots
        ORDER BY timestamp DESC
        LIMIT ?;
        """
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, querySQL, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var snapshots: [ScanHistorySnapshot] = []
        let decoder = JSONDecoder()

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let ts = sqlite3_column_double(stmt, 1)
            let scannedPath = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let totalCap = sqlite3_column_int64(stmt, 3)
            let used = sqlite3_column_int64(stmt, 4)
            let avail = sqlite3_column_int64(stmt, 5)
            let rootBytes = sqlite3_column_int64(stmt, 6)
            let catJSON = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? "{}"
            let folderJSON = sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? "{}"

            let categories = (try? decoder.decode([String: Int64].self, from: Data(catJSON.utf8))) ?? [:]
            let folders = (try? decoder.decode([String: Int64].self, from: Data(folderJSON.utf8))) ?? [:]

            snapshots.append(
                ScanHistorySnapshot(
                    id: id,
                    timestamp: Date(timeIntervalSince1970: ts),
                    scannedPath: scannedPath,
                    totalCapacityBytes: totalCap,
                    usedBytes: used,
                    availableBytes: avail,
                    scannedRootBytes: rootBytes,
                    categoryBreakdown: categories,
                    topFolders: folders
                )
            )
        }
        return snapshots.reversed()
    }

    public func computeGrowthDeltas(snapshots: [ScanHistorySnapshot]) -> [StorageGrowthDelta] {
        guard snapshots.count >= 2,
              let latest = snapshots.last,
              let previous = snapshots.dropLast().last(where: { $0.scannedPath == latest.scannedPath }) else {
            return []
        }

        var deltas: [StorageGrowthDelta] = []

        for (catName, currentBytes) in latest.categoryBreakdown {
            let prevBytes = previous.categoryBreakdown[catName] ?? 0
            if currentBytes != prevBytes {
                deltas.append(
                    StorageGrowthDelta(
                        name: catName,
                        isFolder: false,
                        previousBytes: prevBytes,
                        currentBytes: currentBytes
                    )
                )
            }
        }

        for (folderPath, currentBytes) in latest.topFolders {
            let prevBytes = previous.topFolders[folderPath] ?? 0
            if currentBytes != prevBytes {
                deltas.append(
                    StorageGrowthDelta(
                        name: folderPath,
                        isFolder: true,
                        previousBytes: prevBytes,
                        currentBytes: currentBytes
                    )
                )
            }
        }

        deltas.sort { abs($0.deltaBytes) > abs($1.deltaBytes) }
        return deltas
    }

    public func pruneOldSnapshots(retentionDays: Int) {
        lock.lock()
        defer { lock.unlock() }
        pruneOldSnapshotsUnlocked(retentionDays: retentionDays)
    }

    public func clearAllHistory() {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        sqlite3_exec(db, "DELETE FROM scan_snapshots;", nil, nil, nil)
    }

    private func pruneOldSnapshotsUnlocked(retentionDays: Int) {
        guard retentionDays > 0, let db else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400).timeIntervalSince1970
        var stmt: OpaquePointer?
        let sql = "DELETE FROM scan_snapshots WHERE timestamp < ?;"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }
}
