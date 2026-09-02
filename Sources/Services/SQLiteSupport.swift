import Foundation
import SQLite3

enum LocalSQLiteError: LocalizedError, Equatable {
    case open(String)
    case execute(String)
    case prepare(String)
    case bind(String)
    case step(String)

    var errorDescription: String? {
        switch self {
        case .open(let message): "Could not open the local screen history: \(message)"
        case .execute(let message): "Could not update the local screen history: \(message)"
        case .prepare(let message): "Could not prepare the local screen history query: \(message)"
        case .bind(let message): "Could not bind the local screen history query: \(message)"
        case .step(let message): "Could not read the local screen history: \(message)"
        }
    }
}

/// `@unchecked`: the raw sqlite3 handle is only ever touched from the one
/// actor that owns the connection (`SQLiteScreenHistoryStore`,
/// `CoastLegacyReader`); SQLite itself is compiled thread-safe.
final class LocalSQLiteConnection: @unchecked Sendable {
    private(set) var handle: OpaquePointer?

    init(url: URL, flags: Int32, createParent: Bool = false) throws {
        if createParent {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            if let database { sqlite3_close(database) }
            throw LocalSQLiteError.open(message)
        }
        handle = database
        sqlite3_busy_timeout(database, 2_000)
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func execute(_ sql: String) throws {
        guard let handle else { throw LocalSQLiteError.execute("database is closed") }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorPointer)
            throw LocalSQLiteError.execute(message)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        guard let handle else { throw LocalSQLiteError.prepare("database is closed") }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw LocalSQLiteError.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        return statement
    }

    func message() -> String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed"
    }
}

enum SQLiteValue {
    static func bind(_ value: String?, to statement: OpaquePointer, at index: Int32) throws {
        let result: Int32
        if let value {
            result = value.withCString { pointer in
                sqlite3_bind_text(statement, index, pointer, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else { throw LocalSQLiteError.bind("text parameter \(index)") }
    }

    static func bind(_ value: Double?, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.map { sqlite3_bind_double(statement, index, $0) } ?? sqlite3_bind_null(statement, index)
        guard result == SQLITE_OK else { throw LocalSQLiteError.bind("number parameter \(index)") }
    }

    static func bind(_ value: Int64?, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.map { sqlite3_bind_int64(statement, index, $0) } ?? sqlite3_bind_null(statement, index)
        guard result == SQLITE_OK else { throw LocalSQLiteError.bind("integer parameter \(index)") }
    }

    static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, column)
        else { return nil }
        return String(cString: pointer)
    }
}
