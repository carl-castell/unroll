import Foundation
import UnrollCore

/// One run as recorded in the destination's index.
public struct RunRecord: Sendable, Equatable {
    public let taskID: UUID?
    public let startedAt: Date
    public let imported: Int
    public let duplicates: Int
    public let failed: Int
    public let bytes: Int64
    /// ok, partial, cancelled, aborted, interrupted or running.
    public let status: String
}

/// A transfer that started but wasn't recorded yet, from the journal.
struct PendingTransfer: Equatable {
    let tempName: String
    let key: ItemKey
    /// Set right before the file is moved into place.
    let item: IndexedItem?
}

/// The import index in `<destination>/.unroll/index.sqlite`.
public final class SQLiteIndex: ImportIndex, @unchecked Sendable {
    public static let directoryName = ".unroll"
    public static let fileName = "index.sqlite"
    static let schemaVersion = 1

    private let database: Database
    private let lock = NSLock()

    public static func url(forDestinationRoot root: URL) -> URL {
        root.appending(path: directoryName).appending(path: fileName)
    }

    /// Opens an existing index, or returns nil if the destination has none.
    public static func openExisting(destinationRoot root: URL, readOnly: Bool) throws -> SQLiteIndex? {
        let url = url(forDestinationRoot: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let index = SQLiteIndex(database: try Database(url: url, mode: readOnly ? .readOnly : .readWriteCreate))
        try index.checkSchema()
        return index
    }

    /// Opens the index, creating `.unroll/` and the schema if needed.
    /// - Parameter useWAL: false on network volumes, where SQLite's write-ahead log doesn't work.
    public static func openOrCreate(destinationRoot root: URL, useWAL: Bool = true) throws -> SQLiteIndex {
        let url = url(forDestinationRoot: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let index = SQLiteIndex(database: try Database(url: url, mode: .readWriteCreate))
        try index.database.execute("PRAGMA journal_mode = \(useWAL ? "WAL" : "DELETE"); PRAGMA synchronous = FULL;")
        try index.createSchemaIfNeeded()
        return index
    }

    /// Creates a new, empty index at `url` for a rebuild, with a fresh index ID.
    /// Uses a rollback journal, so the finished file is self-contained and can be moved into place.
    static func createForRebuild(at url: URL) throws -> SQLiteIndex {
        try? FileManager.default.removeItem(at: url)
        let index = SQLiteIndex(database: try Database(url: url, mode: .readWriteCreate))
        try index.database.execute("PRAGMA journal_mode = DELETE; PRAGMA synchronous = FULL;")
        try index.createSchemaIfNeeded()
        try index.locked {
            try index.database.run(
                "INSERT OR REPLACE INTO meta (key, value) VALUES ('rebuilt_at', ?)", [.text(Date().ISO8601Format())]
            )
        }
        return index
    }

    /// Folds an index's write-ahead log back into the file, so the file can be replaced safely.
    static func checkpoint(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let database = try Database(url: url, mode: .readWriteCreate)
        try database.execute("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode = DELETE;")
    }

    private init(database: Database) {
        self.database = database
    }

    // MARK: Reading

    public func importedKeys() throws -> ImportedKeys {
        try locked {
            var exact = Set<ItemKey>()
            var approximate: [ItemKey] = []
            // Times from the device or from unroll's attributes are exact; times read back from
            // file metadata during a rebuild may differ by a second or two.
            try database.query("""
                SELECT capture_date, size, filename, date_source IN ('device', 'attributes') FROM items
                UNION ALL SELECT capture_date, size, filename, 1 FROM aliases
                """) { row in
                let key = Self.key(row, from: 0)
                if row.int(3) == 1 { exact.insert(key) } else { approximate.append(key) }
            }
            return ImportedKeys(exact: exact, approximate: approximate)
        }
    }

    public func files(fromDevice id: DeviceID) throws -> [IndexedFile] {
        try locked {
            var files: [IndexedFile] = []
            try database.query(
                "SELECT capture_date, size, filename, relative_path FROM items WHERE device_id = ? AND role != 'sidecar'",
                [.text(id.rawValue)]
            ) { row in
                if let path = row.text(3) { files.append(IndexedFile(key: Self.key(row, from: 0), relativePath: path)) }
            }
            return files
        }
    }

    public func indexedPaths() throws -> Set<String>? {
        try locked {
            var paths = Set<String>()
            try database.query("SELECT relative_path FROM items") { row in
                if let path = row.text(0) { paths.insert(path) }
            }
            return paths
        }
    }

    public func meta() throws -> IndexMeta {
        try locked {
            var indexID = ""
            try database.query("SELECT value FROM meta WHERE key = 'index_id'") { indexID = $0.text(0) ?? "" }
            var count = 0
            try database.query("SELECT COUNT(*) FROM items") { count = Int($0.int(0)) }
            return IndexMeta(indexID: indexID, itemCount: count)
        }
    }

    func path(forHash hash: Data) throws -> String? {
        try locked {
            var path: String?
            try database.query("SELECT relative_path FROM items WHERE sha256 = ? LIMIT 1", [.blob(hash)]) { path = $0.text(0) }
            return path
        }
    }

    // MARK: Recording

    /// - Parameter dateSource: where the capture time came from: `device`, or for rebuilt entries
    ///   `attributes`, `metadata` or `file-date`.
    public func record(_ item: IndexedItem, dateSource: String = "device") throws {
        try locked { try insert(item, dateSource: dateSource) }
    }

    func beginPending(tempName: String, key: ItemKey) throws {
        try locked {
            try database.run(
                "INSERT INTO pending (temp_name, capture_date, size, filename, started_at) VALUES (?, ?, ?, ?, ?)",
                Self.keyValues(key, prefix: [.text(tempName)]) + [.int(Int64(Date().timeIntervalSince1970))]
            )
        }
    }

    /// Journals where a transfer is about to be moved, so recovery can finish it after a crash.
    func setPendingTarget(tempName: String, item: IndexedItem) throws {
        try locked {
            try database.run("""
                UPDATE pending SET target_path = ?, sha256 = ?, role = ?, asset_id = ?, device_id = ?,
                                   original_filename = ?
                WHERE temp_name = ?
                """, [
                    .text(item.relativePath), .blob(item.sha256), .text(item.role.rawValue), Self.optional(item.assetID),
                    Self.optional(item.deviceID?.rawValue), Self.optional(item.originalFilename), .text(tempName),
                ])
        }
    }

    /// Records the item and clears its journal entry in one transaction.
    func commitPending(tempName: String, item: IndexedItem) throws {
        try locked {
            try database.transaction {
                try insert(item)
                try database.run("DELETE FROM pending WHERE temp_name = ?", [.text(tempName)])
            }
        }
    }

    /// Records `key` as another name for the item at `path` and clears the journal entry.
    func commitAlias(tempName: String, key: ItemKey, of path: String, deviceID: DeviceID) throws {
        try locked {
            try database.transaction {
                try database.run("""
                    INSERT OR IGNORE INTO aliases (capture_date, size, filename, item_id, device_id, recorded_at)
                    SELECT ?, ?, ?, id, ?, ? FROM items WHERE relative_path = ?
                    """, Self.keyValues(key) + [.text(deviceID.rawValue), .int(Int64(Date().timeIntervalSince1970)), .text(path)])
                try database.run("DELETE FROM pending WHERE temp_name = ?", [.text(tempName)])
            }
        }
    }

    func deletePending(tempName: String) throws {
        try locked { try database.run("DELETE FROM pending WHERE temp_name = ?", [.text(tempName)]) }
    }

    func pendingTransfers() throws -> [PendingTransfer] {
        try locked {
            var result: [PendingTransfer] = []
            try database.query("""
                SELECT temp_name, capture_date, size, filename, target_path, sha256, role, asset_id, device_id,
                       original_filename, started_at
                FROM pending
                """) { row in
                let key = Self.key(row, from: 1)
                var item: IndexedItem?
                if let target = row.text(4), let hash = row.blob(5), let role = row.text(6).flatMap(ItemRole.init) {
                    item = IndexedItem(
                        key: key, relativePath: target, sha256: hash, role: role, assetID: row.text(7),
                        deviceID: row.text(8).map(DeviceID.init), originalFilename: row.text(9),
                        importedAt: Date(timeIntervalSince1970: TimeInterval(row.int(10)))
                    )
                }
                result.append(PendingTransfer(tempName: row.text(0) ?? "", key: key, item: item))
            }
            return result
        }
    }

    // MARK: Runs

    func startRun(taskID: UUID, deviceID: DeviceID) throws -> Int64 {
        try locked {
            try database.run(
                "INSERT INTO runs (task_id, device_id, started_at, status) VALUES (?, ?, ?, 'running')",
                [.text(taskID.uuidString), .text(deviceID.rawValue), .int(Int64(Date().timeIntervalSince1970))]
            )
            var id: Int64 = 0
            try database.query("SELECT last_insert_rowid()") { id = $0.int(0) }
            return id
        }
    }

    func pendingPhotosImports() throws -> [String] {
        try locked {
            var paths: [String] = []
            try database.query(
                "SELECT relative_path FROM items WHERE photos_imported = ? AND role != 'sidecar' ORDER BY id",
                [.int(Int64(PhotosImportState.pending.rawValue))]
            ) { row in
                if let path = row.text(0) { paths.append(path) }
            }
            return paths
        }
    }

    func markPhotosImport(_ paths: [String], state: PhotosImportState) throws {
        try locked {
            try database.transaction {
                for path in paths {
                    try database.run(
                        "UPDATE items SET photos_imported = ? WHERE relative_path = ?",
                        [.int(Int64(state.rawValue)), .text(path)]
                    )
                }
            }
        }
    }

    /// Paths of files added to Apple Photos as referenced files.
    func pathsAddedToPhotos() throws -> Set<String> {
        try locked {
            var paths = Set<String>()
            try database.query(
                "SELECT relative_path FROM items WHERE photos_imported = ?", [.int(Int64(PhotosImportState.done.rawValue))]
            ) { row in
                if let path = row.text(0) { paths.insert(path) }
            }
            return paths
        }
    }

    /// Records that a file was moved within the destination. Files not in the index are ignored.
    func moveItem(from: String, to: String) throws {
        try locked {
            try database.run("UPDATE items SET relative_path = ? WHERE relative_path = ?", [.text(to), .text(from)])
        }
    }

    /// The most recent runs into this destination, newest first.
    public func runs(limit: Int = 10) throws -> [RunRecord] {
        try locked {
            var runs: [RunRecord] = []
            try database.query("""
                SELECT task_id, started_at, imported, duplicates, failed, bytes, status
                FROM runs ORDER BY started_at DESC, id DESC LIMIT ?
                """, [.int(Int64(limit))]) { row in
                runs.append(RunRecord(
                    taskID: row.text(0).flatMap(UUID.init(uuidString:)),
                    startedAt: Date(timeIntervalSince1970: TimeInterval(row.int(1))),
                    imported: Int(row.int(2)), duplicates: Int(row.int(3)), failed: Int(row.int(4)),
                    bytes: row.int(5), status: row.text(6) ?? ""
                ))
            }
            return runs
        }
    }

    /// Marks runs that never finished, because the process was killed or the Mac shut down.
    func markUnfinishedRunsInterrupted() throws {
        try locked { try database.run("UPDATE runs SET status = 'interrupted' WHERE status = 'running'") }
    }

    func finishRun(_ id: Int64, summary: SyncSummary) throws {
        let status = if summary.stoppedBecause != nil {
            "aborted"
        } else if !summary.failed.isEmpty {
            "partial"
        } else {
            summary.cancelled ? "cancelled" : "ok"
        }
        try locked {
            try database.run("""
                UPDATE runs SET finished_at = ?, imported = ?, duplicates = ?, unavailable = ?, failed = ?,
                                bytes = ?, status = ?
                WHERE id = ?
                """, [
                    .int(Int64(Date().timeIntervalSince1970)), .int(Int64(summary.imported)), .int(Int64(summary.duplicates)),
                    .int(Int64(summary.unavailable)), .int(Int64(summary.failed.count)), .int(summary.bytes),
                    .text(status), .int(id),
                ])
        }
    }

    // MARK: Helpers

    private func insert(_ item: IndexedItem, dateSource: String = "device") throws {
        try database.run("""
            INSERT INTO items (capture_date, size, filename, relative_path, sha256, role, asset_id,
                               device_id, original_filename, date_source, imported_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, Self.keyValues(item.key) + [
                .text(item.relativePath), .blob(item.sha256), .text(item.role.rawValue), Self.optional(item.assetID),
                Self.optional(item.deviceID?.rawValue), Self.optional(item.originalFilename), .text(dateSource),
                .int(Int64(item.importedAt.timeIntervalSince1970)),
            ])
    }

    private static func keyValues(_ key: ItemKey, prefix: [Database.Value] = []) -> [Database.Value] {
        prefix + [.int(key.captureDate.secondsSince1970), .int(key.size), .text(key.filename)]
    }

    private static func key(_ row: Database.Row, from column: Int32) -> ItemKey {
        ItemKey(
            captureDate: LocalTimestamp(secondsSince1970: row.int(column)),
            size: row.int(column + 1),
            filename: row.text(column + 2) ?? ""
        )
    }

    private static func optional(_ text: String?) -> Database.Value {
        text.map(Database.Value.text) ?? .null
    }

    private func checkSchema() throws {
        try locked {
            var version: String?
            try database.query("SELECT value FROM meta WHERE key = 'schema_version'") { version = $0.text(0) }
            guard version == String(Self.schemaVersion) else {
                throw SQLiteError(code: -1, message: "unsupported index schema version \(version ?? "none")")
            }
        }
    }

    private func createSchemaIfNeeded() throws {
        try locked {
            try database.transaction {
                try database.execute(Self.schema)
                try database.run(
                    "INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', ?), ('index_id', ?), ('created_at', ?)",
                    [.text(String(Self.schemaVersion)), .text(UUID().uuidString), .text(Date().ISO8601Format())]
                )
            }
        }
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// capture_date is the photo's clock time in seconds (see LocalTimestamp), not UTC.
    static let schema = """
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);

        CREATE TABLE IF NOT EXISTS items (
            id                INTEGER PRIMARY KEY,
            capture_date      INTEGER NOT NULL,
            size              INTEGER NOT NULL,
            filename          TEXT    NOT NULL,
            relative_path     TEXT    NOT NULL UNIQUE,
            sha256            BLOB    NOT NULL,
            role              TEXT    NOT NULL,
            asset_id          TEXT,
            device_id         TEXT,
            original_filename TEXT,
            date_source       TEXT    NOT NULL,
            imported_at       INTEGER NOT NULL,
            photos_imported   INTEGER NOT NULL DEFAULT 0
        );
        CREATE UNIQUE INDEX IF NOT EXISTS items_key ON items (capture_date, size, filename);
        CREATE INDEX IF NOT EXISTS items_hash ON items (sha256);

        CREATE TABLE IF NOT EXISTS aliases (
            capture_date INTEGER NOT NULL,
            size         INTEGER NOT NULL,
            filename     TEXT    NOT NULL,
            item_id      INTEGER NOT NULL REFERENCES items (id),
            device_id    TEXT,
            recorded_at  INTEGER NOT NULL,
            PRIMARY KEY (capture_date, size, filename)
        );

        CREATE TABLE IF NOT EXISTS pending (
            temp_name         TEXT PRIMARY KEY,
            capture_date      INTEGER NOT NULL,
            size              INTEGER NOT NULL,
            filename          TEXT    NOT NULL,
            started_at        INTEGER NOT NULL,
            target_path       TEXT,
            sha256            BLOB,
            role              TEXT,
            asset_id          TEXT,
            device_id         TEXT,
            original_filename TEXT
        );

        CREATE TABLE IF NOT EXISTS runs (
            id          INTEGER PRIMARY KEY,
            task_id     TEXT    NOT NULL,
            device_id   TEXT,
            started_at  INTEGER NOT NULL,
            finished_at INTEGER,
            imported    INTEGER,
            duplicates  INTEGER,
            unavailable INTEGER,
            failed      INTEGER,
            bytes       INTEGER,
            status      TEXT
        );
        """
}

public struct SQLiteIndexProvider: IndexProviding {
    public init() {}

    public func existingIndex(at destinationRoot: URL) throws -> (any ImportIndex)? {
        try SQLiteIndex.openExisting(destinationRoot: destinationRoot, readOnly: true)
    }
}
