import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

public enum SQLValue: Sendable, Equatable {
    case null, int(Int64), double(Double), text(String), blob(Data)

    public var int: Int64? { if case .int(let v) = self { v } else { nil } }
    public var double: Double? {
        switch self {
        case .double(let v): v
        case .int(let v): Double(v)
        default: nil
        }
    }
    public var text: String? { if case .text(let v) = self { v } else { nil } }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin wrapper over the system SQLite (which ships with FTS5). One connection,
/// serialised by an internal lock, so it is safe to share across tasks.
public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var transactionDepth = 0

    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let err = lastError()
            sqlite3_close(handle)
            handle = nil // deinit still runs after a throwing init
            throw err
        }
        sqlite3_busy_timeout(handle, 3000)
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
    }

    public static func inMemory() throws -> SQLiteDatabase { try SQLiteDatabase(path: ":memory:") }

    deinit { sqlite3_close(handle) }

    private func lastError() -> SQLiteError {
        SQLiteError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }

    /// Runs one or more statements without parameters.
    public func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    /// Runs a single statement with bound parameters and returns all rows.
    @discardableResult
    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [[SQLValue]] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(stmt) }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch p {
            case .null: rc = sqlite3_bind_null(stmt, idx)
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v):
                // Explicit byte length: with -1 everything after an embedded NUL would be dropped.
                let utf8 = Array(v.utf8)
                rc = utf8.withUnsafeBufferPointer { p in
                    p.withMemoryRebound(to: CChar.self) { sqlite3_bind_text(stmt, idx, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
                }
            case .blob(let v):
                rc = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
            }
            guard rc == SQLITE_OK else { throw lastError() }
        }
        var rows: [[SQLValue]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError() }
            let n = sqlite3_column_count(stmt)
            var row: [SQLValue] = []
            row.reserveCapacity(Int(n))
            for c in 0..<n {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(stmt, c)))
                case SQLITE_FLOAT: row.append(.double(sqlite3_column_double(stmt, c)))
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(stmt, c))))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(stmt, c))
                    row.append(.blob(sqlite3_column_blob(stmt, c).map { Data(bytes: $0, count: count) } ?? Data()))
                default: row.append(.null)
                }
            }
            rows.append(row)
        }
        return rows
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        // Nested calls become savepoints, so an inner failure cannot discard outer work.
        let depth = transactionDepth
        try execute(depth == 0 ? "BEGIN IMMEDIATE" : "SAVEPOINT sp\(depth)")
        transactionDepth += 1
        defer { transactionDepth -= 1 }
        do {
            let r = try body()
            try execute(depth == 0 ? "COMMIT" : "RELEASE sp\(depth)")
            return r
        } catch {
            try? execute(depth == 0 ? "ROLLBACK" : "ROLLBACK TO sp\(depth); RELEASE sp\(depth)")
            throw error
        }
    }

    /// Applies numbered migrations once each, tracked in `PRAGMA user_version`.
    public func migrate(_ migrations: [String]) throws {
        // The version is read inside the write lock so two processes cannot both apply a step.
        try transaction {
            let current = Int(try query("PRAGMA user_version").first?.first?.int ?? 0)
            for (i, sql) in migrations.enumerated() where i >= current {
                try execute(sql)
                try execute("PRAGMA user_version = \(i + 1)")
            }
        }
    }
}
