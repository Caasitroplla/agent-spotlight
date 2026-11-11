import Foundation
import CSQLite

public enum SQLValue: Sendable {
    case text(String), integer(Int64), real(Double), null
    public var string: String {
        switch self { case .text(let value): return value; case .integer(let value): return String(value); case .real(let value): return String(value); case .null: return "" }
    }
    public var int: Int { Int(string) ?? 0 }
    public var double: Double { Double(string) ?? 0 }
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let description: String
}

public final class SQLite {
    private var handle: OpaquePointer?
    public init(url: URL, readOnly: Bool = true) throws {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database"
            if let handle { sqlite3_close(handle) }; handle = nil
            throw SQLiteError(description: detail)
        }
        sqlite3_busy_timeout(handle, 500)
        if readOnly { try execute("PRAGMA query_only=ON") }
    }
    deinit { if let handle { sqlite3_close(handle) } }
    public func execute(_ sql: String, _ values: [SQLValue] = []) throws { _ = try query(sql, values) }
    public func query(_ sql: String, _ values: [SQLValue] = []) throws -> [[String: SQLValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text): result = sqlite3_bind_text(statement, index, text, -1, transient)
            case .integer(let number): result = sqlite3_bind_int64(statement, index, number)
            case .real(let number): result = sqlite3_bind_double(statement, index, number)
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw error() }
        }
        var rows: [[String: SQLValue]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return rows }
            guard step == SQLITE_ROW else { throw error() }
            var row: [String: SQLValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let key = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row[key] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: row[key] = .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT: row[key] = .text(String(cString: sqlite3_column_text(statement, index)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    if let bytes = sqlite3_column_blob(statement, index) { row[key] = .text(String(decoding: Data(bytes: bytes, count: count), as: UTF8.self)) }
                    else { row[key] = .null }
                default: row[key] = .null
                }
            }
            rows.append(row)
        }
    }
    public func columns(_ table: String) throws -> Set<String> { Set(try query("PRAGMA table_info(\(table))").compactMap { $0["name"]?.string }) }
    private func error() -> SQLiteError { SQLiteError(description: String(cString: sqlite3_errmsg(handle))) }
}
