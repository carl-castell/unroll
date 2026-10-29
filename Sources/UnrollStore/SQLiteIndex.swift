import Foundation
import UnrollCore

/// One file recorded in the index after it was copied and verified.
public struct IndexedItem: Sendable, Equatable {
    public let key: ItemKey
    /// Relative to the destination root, e.g. `2026/2026-06/IMG_2211.HEIC`.
    public let relativePath: String
    public let sha256: Data
    public let role: ItemRole
    public let assetID: String?
    public let deviceID: DeviceID?
    public let originalFilename: String?
    public let importedAt: Date

    public init(
        key: ItemKey, relativePath: String, sha256: Data, role: ItemRole, assetID: String?,
        deviceID: DeviceID?, originalFilename: String?, importedAt: Date
    ) {
        self.key = key
        self.relativePath = relativePath
        self.sha256 = sha256
        self.role = role
        self.assetID = assetID
        self.deviceID = deviceID
        self.originalFilename = originalFilename
        self.importedAt = importedAt
    }
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

    private init(database: Database) {
        self.database = database
    }

    public func importedKeys() throws -> Set<ItemKey> {
        try locked {
            var keys = Set<ItemKey>()
            try database.query("""
                SELECT capture_date, size, filename FROM items
                UNION ALL SELECT capture_date, size, filename FROM aliases
                """) { row in
                keys.insert(ItemKey(
                    captureDate: LocalTimestamp(secondsSince1970: row.int(0)), size: row.int(1), filename: row.text(2) ?? ""
                ))
            }
            return keys
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

    public func record(_ item: IndexedItem) throws {
        try locked {
            try database.run("""
                INSERT INTO items (capture_date, size, filename, relative_path, sha256, role, asset_id,
                                   device_id, original_filename, date_source, imported_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'device', ?)
                """, [
                    .int(item.key.captureDate.secondsSince1970), .int(item.key.size), .text(item.key.filename),
                    .text(item.relativePath), .blob(item.sha256), .text(item.role.rawValue),
                    item.assetID.map(Database.Value.text) ?? .null,
                    item.deviceID.map { .text($0.rawValue) } ?? .null,
                    item.originalFilename.map(Database.Value.text) ?? .null,
                    .int(Int64(item.importedAt.timeIntervalSince1970)),
                ])
        }
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
            temp_name    TEXT PRIMARY KEY,
            capture_date INTEGER NOT NULL,
            size         INTEGER NOT NULL,
            filename     TEXT    NOT NULL,
            target_path  TEXT,
            sha256       BLOB,
            started_at   INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS runs (
            id          INTEGER PRIMARY KEY,
            task_id     TEXT    NOT NULL,
            device_id   TEXT,
            started_at  INTEGER NOT NULL,
            finished_at INTEGER,
            imported    INTEGER,
            skipped     INTEGER,
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
