import Foundation
import SQLite3

/// A SQLite database through the system library: parameterized statements, cached prepared
/// statements, transactions and numbered migrations. Nothing more.
///
/// ``run(_:_:)`` and ``query(_:_:_:)`` stop when the calling task is cancelled, even in the middle of
/// a long scan, and throw `CancellationError`, so a custom-filtered list can drop a superseded
/// search at once.
///
/// It is not `Sendable`. Give each database one owner, usually an actor, and do all work there, off
/// the main thread:
///
/// ```swift
/// actor HistoryStore {
///     private let db: SQLiteDatabase
///     init(url: URL) throws {
///         db = try SQLiteDatabase(url: url)
///         try db.migrate(["CREATE TABLE entry (id INTEGER PRIMARY KEY, text TEXT NOT NULL, date REAL NOT NULL)"])
///     }
/// }
/// ```
public final class SQLiteDatabase {
    /// How to open a database.
    public struct Options: Hashable, Sendable {
        public var readOnly: Bool
        /// Write-ahead logging: readers never block the writer. On by default, as the architecture asks.
        public var writeAheadLog: Bool
        /// How long a statement waits for a lock held by another connection.
        public var busyTimeout: Duration
        /// Overwrites what a delete frees, overflow pages included, so a deleted row cannot be read
        /// back from the file. On by default: every database here holds the user's data. The
        /// system's SQLite otherwise clears only the row's own page.
        public var secureDelete: Bool

        public init(
            readOnly: Bool = false, writeAheadLog: Bool = true, busyTimeout: Duration = .seconds(2),
            secureDelete: Bool = true
        ) {
            self.readOnly = readOnly
            self.writeAheadLog = writeAheadLog
            self.busyTimeout = busyTimeout
            self.secureDelete = secureDelete
        }
    }

    /// Prepared statements kept for reuse. SQL built with a varying number of `?`, such as an `IN`
    /// list, would otherwise grow the cache without end.
    private static let statementCacheLimit = 64

    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    /// The cached statements' SQL, oldest first, for evicting.
    private var statementOrder: [String] = []

    /// Opens or creates the database file, creating its folder when needed.
    public convenience init(url: URL, options: Options = Options()) throws {
        if !options.readOnly {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try self.init(path: url.path, options: options)
    }

    /// A private database that lives in memory until it is closed.
    public static func inMemory() throws -> SQLiteDatabase {
        try SQLiteDatabase(path: ":memory:", options: Options(writeAheadLog: false))
    }

    private init(path: String, options: Options) throws {
        var opened: OpaquePointer?
        let flags = options.readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let code = sqlite3_open_v2(path, &opened, flags, nil)
        guard code == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            sqlite3_close_v2(opened)
            throw SQLiteError(code: code, message: message)
        }
        handle = opened
        let milliseconds =
            options.busyTimeout.components.seconds * 1000 + options.busyTimeout.components.attoseconds
            / 1_000_000_000_000_000
        sqlite3_busy_timeout(opened, Int32(clamping: milliseconds))
        if options.writeAheadLog && !options.readOnly {
            try execute("PRAGMA journal_mode = WAL")
        }
        if options.secureDelete && !options.readOnly {
            try execute("PRAGMA secure_delete = ON")
        }
        try execute("PRAGMA foreign_keys = ON")
    }

    /// Copies the write-ahead log into the database and empties the log file, so pages a delete
    /// replaced are not kept in the log. Does nothing for a database without a log.
    public func checkpointAndTruncateLog() throws {
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    deinit {
        close()
    }

    /// Closes the database. Later calls throw. Called automatically when the database is released.
    public func close() {
        for statement in statements.values {
            sqlite3_finalize(statement)
        }
        statements.removeAll()
        statementOrder.removeAll()
        if let handle {
            sqlite3_close_v2(handle)
        }
        handle = nil
    }

    /// Runs one or more statements separated by semicolons, with no parameters and no results. For
    /// schema changes and pragmas.
    public func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(try connection(), sql, nil, nil, &message)
        guard code == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "statement failed"
            sqlite3_free(message)
            throw SQLiteError(code: code, message: text, sql: sql)
        }
    }

    /// Runs one statement with parameters bound to its `?` placeholders, discarding any rows. Throws
    /// `CancellationError` when the calling task is cancelled.
    public func run(_ sql: String, _ parameters: [SQLiteValue] = []) throws {
        try Task.checkCancellation()
        let statement = try prepare(sql, parameters)
        defer { reset(statement) }
        try stoppingWhenCancelled {
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return }
                if code != SQLITE_ROW { throw lastError(code, sql: sql) }
            }
        }
    }

    /// Runs one query with parameters and maps each result row. Throws `CancellationError` when the
    /// calling task is cancelled.
    public func query<Result>(_ sql: String, _ parameters: [SQLiteValue] = [], _ map: (SQLiteRow) throws -> Result)
        throws
        -> [Result]
    {
        try Task.checkCancellation()
        let statement = try prepare(sql, parameters)
        defer { reset(statement) }
        return try stoppingWhenCancelled {
            var results: [Result] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return results }
                guard code == SQLITE_ROW else { throw lastError(code, sql: sql) }
                results.append(try map(SQLiteRow(statement: statement)))
            }
        }
    }

    /// Runs the body in a transaction: committed when it returns, rolled back when it throws.
    public func transaction<Result>(_ body: () throws -> Result) throws -> Result {
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

    /// Brings the schema up to date. `migrations[n]` moves the database from version n to n + 1; the
    /// version is kept in `PRAGMA user_version`. Each migration runs in its own transaction, and only
    /// the ones above the current version run. Never edit a migration that has shipped; append one.
    public func migrate(_ migrations: [String]) throws {
        let current = try userVersion()
        guard current < migrations.count else { return }
        for version in current..<migrations.count {
            try transaction {
                try execute(migrations[version])
                try execute("PRAGMA user_version = \(version + 1)")
            }
        }
    }

    /// The schema version stored in `PRAGMA user_version`.
    public func userVersion() throws -> Int {
        Int(try query("PRAGMA user_version") { $0.int(0) ?? 0 }.first ?? 0)
    }

    /// The row ID of the last successful insert on this connection.
    public var lastInsertRowID: Int64 {
        handle.map(sqlite3_last_insert_rowid) ?? 0
    }

    /// How many rows the last insert, update or delete changed.
    public var changes: Int {
        handle.map { Int(sqlite3_changes($0)) } ?? 0
    }

    /// Runs the body with a progress handler that interrupts SQLite when the current task is
    /// cancelled, and turns the interruption into `CancellationError`. Schema changes, commits and
    /// rollbacks run outside it, so they always finish.
    private func stoppingWhenCancelled<Result>(_ body: () throws -> Result) throws -> Result {
        let database = try connection()
        // The handler runs on this thread inside sqlite3_step, every 1,000 virtual machine
        // instructions; returning nonzero makes the step fail with SQLITE_INTERRUPT.
        sqlite3_progress_handler(database, 1000, { _ in Task.isCancelled ? 1 : 0 }, nil)
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        do {
            return try body()
        } catch let error as SQLiteError where error.code == SQLITE_INTERRUPT {
            throw CancellationError()
        }
    }

    private func connection() throws -> OpaquePointer {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "the database is closed") }
        return handle
    }

    private func prepare(_ sql: String, _ parameters: [SQLiteValue]) throws -> OpaquePointer {
        let database = try connection()
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
        } else {
            var prepared: OpaquePointer?
            let code = sqlite3_prepare_v3(database, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &prepared, nil)
            guard code == SQLITE_OK, let prepared else { throw lastError(code, sql: sql) }
            if statementOrder.count >= Self.statementCacheLimit {
                let oldest = statementOrder.removeFirst()
                if let evicted = statements.removeValue(forKey: oldest) { sqlite3_finalize(evicted) }
            }
            statements[sql] = prepared
            statementOrder.append(sql)
            statement = prepared
        }
        let expected = Int(sqlite3_bind_parameter_count(statement))
        guard expected == parameters.count else {
            throw SQLiteError(
                code: SQLITE_RANGE, message: "expected \(expected) parameters, got \(parameters.count)", sql: sql)
        }
        for (offset, value) in parameters.enumerated() {
            let code = bind(value, at: Int32(offset + 1), in: statement)
            guard code == SQLITE_OK else {
                reset(statement)
                throw lastError(code, sql: sql)
            }
        }
        return statement
    }

    private func bind(_ value: SQLiteValue, at index: Int32, in statement: OpaquePointer) -> Int32 {
        switch value {
        case .null:
            return sqlite3_bind_null(statement, index)
        case .integer(let integer):
            return sqlite3_bind_int64(statement, index, integer)
        case .real(let real):
            return sqlite3_bind_double(statement, index, real)
        case .text(let text):
            // SQLITE_TRANSIENT makes SQLite copy the bytes before the temporary C string goes away.
            return sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
        case .blob(let data):
            guard !data.isEmpty else { return sqlite3_bind_zeroblob(statement, index, 0) }
            // The buffer is valid for the closure; SQLITE_TRANSIENT makes SQLite copy it first.
            return data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
            }
        }
    }

    private func reset(_ statement: OpaquePointer) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    private func lastError(_ code: Int32, sql: String) -> SQLiteError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "the database is closed"
        return SQLiteError(code: code, message: message, sql: sql)
    }
}

/// SQLite's `SQLITE_TRANSIENT` destructor: copy the bound bytes. The C macro does not import.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
