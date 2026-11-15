import Foundation
import SQLite3

/// A SQLite connection used inside one function: opened, queried and closed on one thread. Only
/// the Firefox reader uses it. Every failure becomes a ``BookmarkReadError``.
nonisolated final class SQLiteConnection {
    private var handle: OpaquePointer?

    /// Opens a database image held in memory, read-only. Nothing touches the disk.
    ///
    /// A file Firefox wrote in write-ahead-log mode says so in bytes 18 and 19 of its header. A
    /// database in memory cannot use that mode, so the copy is marked as an ordinary one first.
    init(image: Data) throws(BookmarkReadError) {
        let header = Array("SQLite format 3\0".utf8)
        guard image.count >= 100, image.prefix(16).elementsEqual(header) else { throw .damaged }
        guard let buffer = sqlite3_malloc64(UInt64(image.count)) else { throw .unreadable }
        let bytes = buffer.assumingMemoryBound(to: UInt8.self)
        image.copyBytes(to: bytes, count: image.count)
        if bytes[18] == 2 { bytes[18] = 1 }
        if bytes[19] == 2 { bytes[19] = 1 }
        var opened: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &opened, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let opened else {
            sqlite3_free(buffer)
            sqlite3_close_v2(opened)
            throw .unreadable
        }
        handle = opened
        // SQLite frees the buffer when the connection closes, or at once if this call fails.
        let flags = UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_READONLY)
        let size = Int64(image.count)
        guard sqlite3_deserialize(opened, "main", bytes, size, size, flags) == SQLITE_OK else { throw .damaged }
        try execute("PRAGMA trusted_schema = OFF")
    }

    /// Opens a database file. The Firefox reader opens only its own private copy.
    init(path: String, readOnly: Bool) throws(BookmarkReadError) {
        var opened: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(path, &opened, flags | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK, let opened else {
            sqlite3_close_v2(opened)
            throw .unreadable
        }
        handle = opened
        try execute("PRAGMA trusted_schema = OFF")
    }

    /// An empty database in memory, for building synthetic fixtures.
    init() throws(BookmarkReadError) {
        var opened: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &opened, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let opened else {
            sqlite3_close_v2(opened)
            throw .unreadable
        }
        handle = opened
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    /// Runs statements that return no rows.
    func execute(_ sql: String) throws(BookmarkReadError) {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw Self.error(handle) }
    }

    /// A value bound to a `?` in ``run(_:_:)``.
    enum Value {
        case int(Int64)
        case text(String)
        case null
    }

    /// Runs one statement with values bound to its `?`s, in order.
    func run(_ sql: String, _ values: [Value]) throws(BookmarkReadError) {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
            sqlite3_finalize(prepared)
            throw Self.error(handle)
        }
        defer { sqlite3_finalize(prepared) }
        // SQLite copies the text before the call returns.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let number): sqlite3_bind_int64(prepared, index, number)
            case .text(let text): sqlite3_bind_text(prepared, index, text, -1, transient)
            case .null: sqlite3_bind_null(prepared, index)
            }
        }
        guard sqlite3_step(prepared) == SQLITE_DONE else { throw Self.error(handle) }
    }

    /// True when the schema has a real table of this name, not a view that could run anything.
    func hasTable(_ name: String, schema: String = "main") throws(BookmarkReadError) -> Bool {
        var found = false
        try query("SELECT 1 FROM \(schema).sqlite_master WHERE type = 'table' AND name = '\(name)'") { _ in
            found = true
        }
        return found
    }

    /// Runs a query and hands each row to `row`.
    func query(_ sql: String, row: (Statement) -> Void) throws(BookmarkReadError) {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
            sqlite3_finalize(prepared)
            throw Self.error(handle)
        }
        defer { sqlite3_finalize(prepared) }
        while true {
            switch sqlite3_step(prepared) {
            case SQLITE_ROW: row(Statement(handle: prepared))
            case SQLITE_DONE: return
            default: throw Self.error(handle)
            }
        }
    }

    /// The bytes of one schema of this connection, such as an attached memory database.
    func serialize(schema: String) throws(BookmarkReadError) -> Data {
        var size: Int64 = 0
        guard let bytes = sqlite3_serialize(handle, schema, &size, 0) else { throw .unreadable }
        defer { sqlite3_free(bytes) }
        return Data(bytes: bytes, count: Int(size))
    }

    private static func error(_ handle: OpaquePointer?) -> BookmarkReadError {
        switch sqlite3_errcode(handle) & 0xFF {
        case SQLITE_CORRUPT, SQLITE_NOTADB, SQLITE_ERROR, SQLITE_SCHEMA, SQLITE_MISMATCH, SQLITE_RANGE: .damaged
        case SQLITE_PERM, SQLITE_AUTH: .accessDenied
        case SQLITE_TOOBIG: .tooLarge
        default: .unreadable
        }
    }

    /// The current row of a query. Valid only inside the closure that receives it.
    struct Statement {
        fileprivate let handle: OpaquePointer

        func int(_ column: Int32) -> Int64? {
            sqlite3_column_type(handle, column) == SQLITE_INTEGER ? sqlite3_column_int64(handle, column) : nil
        }

        func text(_ column: Int32) -> String? {
            guard sqlite3_column_type(handle, column) != SQLITE_NULL, let bytes = sqlite3_column_text(handle, column)
            else { return nil }
            let count = Int(sqlite3_column_bytes(handle, column))
            return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
        }
    }
}
