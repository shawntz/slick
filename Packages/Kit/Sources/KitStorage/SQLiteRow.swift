import Foundation
import SQLite3

/// The current result row while ``SQLiteDatabase/query(_:_:_:)`` runs its closure. Read the columns
/// by position and copy out what you need; the row is only valid inside the closure.
public struct SQLiteRow {
    let statement: OpaquePointer

    /// How many columns the row has.
    public var columnCount: Int {
        Int(sqlite3_column_count(statement))
    }

    /// The column's name as the query spells it.
    public func columnName(_ index: Int) -> String {
        sqlite3_column_name(statement, Int32(index)).map { String(cString: $0) } ?? ""
    }

    /// True when the column is NULL.
    public func isNull(_ index: Int) -> Bool {
        sqlite3_column_type(statement, Int32(index)) == SQLITE_NULL
    }

    /// The column as an integer; nil when NULL.
    public func int(_ index: Int) -> Int64? {
        isNull(index) ? nil : sqlite3_column_int64(statement, Int32(index))
    }

    /// The column as a floating-point number; nil when NULL.
    public func double(_ index: Int) -> Double? {
        isNull(index) ? nil : sqlite3_column_double(statement, Int32(index))
    }

    /// The column as a Boolean, nonzero meaning true; nil when NULL.
    public func bool(_ index: Int) -> Bool? {
        int(index).map { $0 != 0 }
    }

    /// The column as a date stored by ``SQLiteValue/date(_:)``; nil when NULL.
    public func date(_ index: Int) -> Date? {
        double(index).map(Date.init(timeIntervalSince1970:))
    }

    /// The column as UTF-8 text; nil when NULL.
    public func string(_ index: Int) -> String? {
        guard !isNull(index), let bytes = sqlite3_column_text(statement, Int32(index)) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, Int32(index)))
        // SQLite keeps the bytes valid until the next step or reset; they are copied here.
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    /// The column as bytes; nil when NULL.
    public func data(_ index: Int) -> Data? {
        guard !isNull(index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, Int32(index)))
        guard count > 0, let bytes = sqlite3_column_blob(statement, Int32(index)) else { return Data() }
        // Copied before the next step invalidates SQLite's buffer.
        return Data(bytes: bytes, count: count)
    }

    /// The column in its stored class.
    public func value(_ index: Int) -> SQLiteValue {
        switch sqlite3_column_type(statement, Int32(index)) {
        case SQLITE_INTEGER: .integer(sqlite3_column_int64(statement, Int32(index)))
        case SQLITE_FLOAT: .real(sqlite3_column_double(statement, Int32(index)))
        case SQLITE_TEXT: .text(string(index) ?? "")
        case SQLITE_BLOB: .blob(data(index) ?? Data())
        default: .null
        }
    }
}
