import Foundation
import SQLite3

/// SQLite copies bound text immediately (SQLITE_TRANSIENT), so Swift strings can be released after binding.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A value bound to a positional SQL parameter.
public enum SQLValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    public static func optional(_ value: String?) -> SQLValue {
        value.map(SQLValue.text) ?? .null
    }

    public static func optional(_ value: Double?) -> SQLValue {
        value.map(SQLValue.real) ?? .null
    }

    public static func int(_ value: Int) -> SQLValue {
        .integer(Int64(value))
    }

    public static func bool(_ value: Bool) -> SQLValue {
        .integer(value ? 1 : 0)
    }
}

/// A SQLite error, with the failing statement for diagnostics.
public struct SQLiteError: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public let sql: String?

    public var isConstraintViolation: Bool {
        (code & 0xFF) == SQLITE_CONSTRAINT
    }

    public var description: String {
        var text = "SQLite error \(code): \(message)"
        if let sql {
            let firstLine = sql.split(whereSeparator: \.isNewline).first.map(String.init) ?? sql
            text += " [\(firstLine)]"
        }
        return text
    }

    public var errorDescription: String? {
        description
    }
}

/// One result row; valid only inside the closure passed to `Database.query`.
public struct Row {
    fileprivate let statement: OpaquePointer

    public func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    public func string(_ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    public func optionalString(_ column: Int32) -> String? {
        isNull(column) ? nil : string(column)
    }

    public func int(_ column: Int32) -> Int {
        Int(sqlite3_column_int64(statement, column))
    }

    public func int64(_ column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }

    public func double(_ column: Int32) -> Double {
        sqlite3_column_double(statement, column)
    }

    public func optionalDouble(_ column: Int32) -> Double? {
        isNull(column) ? nil : double(column)
    }

    public func bool(_ column: Int32) -> Bool {
        int(column) != 0
    }
}

/// A thin, serialised wrapper around one SQLite connection.
public final class Database {
    public let path: String
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()

    public init(path: String) throws {
        self.path = path
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(path, &connection, flags, nil)
        guard status == SQLITE_OK, let opened = connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "status \(status)"
            if let connection { sqlite3_close_v2(connection) }
            throw SQLiteError(code: status, message: message, sql: nil)
        }
        handle = opened
        sqlite3_extended_result_codes(opened, 1)
        sqlite3_busy_timeout(opened, 5_000)
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = FULL")
        // Deleted content is overwritten with zeros instead of lingering in free pages.
        try execute("PRAGMA secure_delete = ON")
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    private var currentErrorMessage: String {
        guard let handle else { return "the database connection is closed" }
        return String(cString: sqlite3_errmsg(handle))
    }

    /// Runs one or more statements without parameters: schema scripts and pragmas.
    public func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard status == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? currentErrorMessage
            sqlite3_free(errorPointer)
            throw SQLiteError(code: status, message: message, sql: sql)
        }
    }

    /// Runs a single statement and maps each result row.
    @discardableResult
    public func query<T>(_ sql: String, _ parameters: [SQLValue] = [], _ transform: (Row) throws -> T) throws -> [T] {
        lock.lock()
        defer { lock.unlock() }
        var prepared: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &prepared, nil)
        guard status == SQLITE_OK, let statement = prepared else {
            throw SQLiteError(code: status, message: currentErrorMessage, sql: sql)
        }
        defer { sqlite3_finalize(statement) }
        try bind(parameters, to: statement, sql: sql)
        var rows: [T] = []
        while true {
            let step = sqlite3_step(statement)
            switch step {
            case SQLITE_ROW:
                let value = try transform(Row(statement: statement))
                rows.append(value)
            case SQLITE_DONE:
                return rows
            default:
                throw SQLiteError(code: step, message: currentErrorMessage, sql: sql)
            }
        }
    }

    /// Runs a single statement that returns no rows.
    public func run(_ sql: String, _ parameters: [SQLValue] = []) throws {
        try query(sql, parameters) { _ in () }
    }

    /// The first column of the first row as an integer, if any.
    public func int(_ sql: String, _ parameters: [SQLValue] = []) throws -> Int? {
        let values = try query(sql, parameters) { (row: Row) -> Int? in
            row.isNull(0) ? nil : row.int(0)
        }
        return values.compactMap { $0 }.first
    }

    /// Runs `body` in an immediate transaction: everything is committed together, or nothing is.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func userVersion() throws -> Int {
        try int("PRAGMA user_version") ?? 0
    }

    /// Rows changed by the most recent INSERT, UPDATE or DELETE on this connection.
    public var changesInLastStatement: Int {
        lock.lock()
        defer { lock.unlock() }
        return Int(sqlite3_changes(handle))
    }

    private func bind(_ parameters: [SQLValue], to statement: OpaquePointer, sql: String) throws {
        let expected = Int(sqlite3_bind_parameter_count(statement))
        guard expected == parameters.count else {
            throw SQLiteError(
                code: SQLITE_MISUSE,
                message: "expected \(expected) parameters, got \(parameters.count)",
                sql: sql
            )
        }
        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .null:
                status = sqlite3_bind_null(statement, index)
            case .integer(let number):
                status = sqlite3_bind_int64(statement, index, number)
            case .real(let number):
                status = sqlite3_bind_double(statement, index, number)
            case .text(let text):
                status = sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
            }
            guard status == SQLITE_OK else {
                throw SQLiteError(code: status, message: currentErrorMessage, sql: sql)
            }
        }
    }
}
