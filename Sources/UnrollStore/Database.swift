import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String

    public var description: String { "SQLite error \(code): \(message)" }
}

/// A minimal wrapper around the system SQLite library. Not thread-safe; callers serialize access.
final class Database {
    enum Mode {
        case readOnly, readWriteCreate
    }

    enum Value {
        case int(Int64), text(String), blob(Data), null
    }

    struct Row {
        fileprivate let statement: OpaquePointer

        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        func blob(_ column: Int32) -> Data? {
            guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        }
    }

    private var handle: OpaquePointer?

    init(url: URL, mode: Mode) throws {
        let flags = switch mode {
        case .readOnly: SQLITE_OPEN_READONLY
        case .readWriteCreate: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        }
        let code = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard code == SQLITE_OK else {
            let error = SQLiteError(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed")
            sqlite3_close(handle)
            throw error
        }
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Runs one or more statements without parameters.
    func execute(_ sql: String) throws {
        try check(sqlite3_exec(handle, sql, nil, nil, nil))
    }

    func run(_ sql: String, _ values: [Value] = []) throws {
        try query(sql, values) { _ in }
    }

    func query(_ sql: String, _ values: [Value] = [], row: (Row) throws -> Void) throws {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            try bind(value, at: Int32(index + 1), to: statement)
        }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return }
            guard code == SQLITE_ROW, let statement else { try check(code); return }
            try row(Row(statement: statement))
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ value: Value, at index: Int32, to statement: OpaquePointer?) throws {
        let code: Int32 = switch value {
        case .int(let v): sqlite3_bind_int64(statement, index, v)
        case .text(let v): sqlite3_bind_text(statement, index, v, -1, Self.transient)
        case .blob(let v): v.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient) }
        case .null: sqlite3_bind_null(statement, index)
        }
        try check(code)
    }

    private func check(_ code: Int32) throws {
        guard code == SQLITE_OK || code == SQLITE_DONE || code == SQLITE_ROW else {
            throw SQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle)))
        }
    }
}
