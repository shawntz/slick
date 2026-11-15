import Foundation

/// A value SQLite stores: one of its five storage classes.
public enum SQLiteValue: Hashable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    /// A date, stored as seconds since 1970 so SQL can compare and sort it.
    public static func date(_ date: Date) -> SQLiteValue {
        .real(date.timeIntervalSince1970)
    }

    /// A Boolean, stored as 0 or 1.
    public static func bool(_ value: Bool) -> SQLiteValue {
        .integer(value ? 1 : 0)
    }

    /// Text, or NULL for nil.
    public init(_ value: String?) {
        self = value.map(SQLiteValue.text) ?? .null
    }

    /// An integer, or NULL for nil.
    public init(_ value: Int?) {
        self = value.map { .integer(Int64($0)) } ?? .null
    }

    /// An integer, or NULL for nil.
    public init(_ value: Int64?) {
        self = value.map(SQLiteValue.integer) ?? .null
    }

    /// A number, or NULL for nil.
    public init(_ value: Double?) {
        self = value.map(SQLiteValue.real) ?? .null
    }

    /// Bytes, or NULL for nil.
    public init(_ value: Data?) {
        self = value.map(SQLiteValue.blob) ?? .null
    }

    /// A date as seconds since 1970, or NULL for nil.
    public init(_ value: Date?) {
        self = value.map(SQLiteValue.date) ?? .null
    }

    /// A Boolean as 0 or 1, or NULL for nil.
    public init(_ value: Bool?) {
        self = value.map(SQLiteValue.bool) ?? .null
    }
}

extension SQLiteValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) {
        self = .text(value)
    }

    public init(integerLiteral value: Int64) {
        self = .integer(value)
    }

    public init(floatLiteral value: Double) {
        self = .real(value)
    }

    public init(nilLiteral: ()) {
        self = .null
    }
}

/// An error from SQLite, with its result code and message.
public struct SQLiteError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The SQLite result code, such as 19 for a constraint violation.
    public var code: Int32
    public var message: String
    /// The statement that failed, when there was one.
    public var sql: String?

    public init(code: Int32, message: String, sql: String? = nil) {
        self.code = code
        self.message = message
        self.sql = sql
    }

    public var description: String {
        "SQLite error \(code): \(message)" + (sql.map { " in \"\($0)\"" } ?? "")
    }
}
