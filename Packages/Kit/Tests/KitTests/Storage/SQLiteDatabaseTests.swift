import Foundation
import KitStorage
import KitTesting
import Testing

@Suite("SQLiteDatabase")
struct SQLiteDatabaseTests {
    private func database() throws -> SQLiteDatabase {
        let db = try SQLiteDatabase.inMemory()
        try db.migrate([
            "CREATE TABLE item (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, score REAL, data BLOB, seen REAL)"
        ])
        return db
    }

    @Test func roundTripsEveryStorageClass() throws {
        let db = try database()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try db.run(
            "INSERT INTO item (name, score, data, seen) VALUES (?, ?, ?, ?)",
            ["café 😀", 2.5, .blob(Data([0, 1, 2])), .date(date)])
        try db.run(
            "INSERT INTO item (name, score, data, seen) VALUES (?, ?, ?, ?)", ["empty", nil, .blob(Data()), nil])
        #expect(db.lastInsertRowID == 2)
        let rows = try db.query("SELECT name, score, data, seen FROM item ORDER BY id") { row in
            (row.string(0), row.double(1), row.data(2), row.date(3))
        }
        #expect(rows.count == 2)
        #expect(rows[0].0 == "café 😀")
        #expect(rows[0].1 == 2.5)
        #expect(rows[0].2 == Data([0, 1, 2]))
        #expect(rows[0].3 == date)
        #expect(rows[1].1 == nil)
        #expect(rows[1].2 == Data())
        #expect(rows[1].3 == nil)
    }

    @Test func readsValuesInTheirStoredClass() throws {
        let db = try database()
        try db.run("INSERT INTO item (name, score) VALUES (?, ?)", ["a", 1.5])
        let values = try db.query("SELECT id, name, score, data FROM item") { row in
            (0..<row.columnCount).map(row.value)
        }
        #expect(values == [[.integer(1), .text("a"), .real(1.5), .null]])
    }

    @Test func rollsBackAFailedTransaction() throws {
        let db = try database()
        struct Stop: Error {}
        #expect(throws: Stop.self) {
            try db.transaction {
                try db.run("INSERT INTO item (name) VALUES (?)", ["kept?"])
                throw Stop()
            }
        }
        #expect(try db.query("SELECT COUNT(*) FROM item") { $0.int(0) } == [0])
    }

    @Test func reportsConstraintsAndParameterMistakes() throws {
        let db = try database()
        try db.run("INSERT INTO item (name) VALUES (?)", ["a"])
        let duplicate = #expect(throws: SQLiteError.self) { try db.run("INSERT INTO item (name) VALUES (?)", ["a"]) }
        #expect(duplicate?.code == 19)
        let count = #expect(throws: SQLiteError.self) { try db.run("INSERT INTO item (name) VALUES (?)", []) }
        #expect(count?.message == "expected 1 parameters, got 0")
        // The failed statements left nothing bound or half-run.
        try db.run("INSERT INTO item (name) VALUES (?)", ["b"])
        #expect(db.changes == 1)
    }

    @Test func migratesOnlyWhatIsNew() throws {
        let db = try SQLiteDatabase.inMemory()
        let steps = ["CREATE TABLE a (x)", "CREATE TABLE b (y)"]
        try db.migrate(steps)
        try db.migrate(steps)
        #expect(try db.userVersion() == 2)
        try db.migrate(steps + ["ALTER TABLE a ADD COLUMN z"])
        #expect(try db.userVersion() == 3)
    }

    @Test func filesUseWriteAheadLoggingInAFolderTheyCreate() throws {
        let storage = FakeStorage()
        let url = storage.dataDirectory(for: "demo").appending(path: "nested/test.sqlite")
        let db = try SQLiteDatabase(url: url)
        #expect(try db.query("PRAGMA journal_mode") { $0.string(0) } == ["wal"])
        db.close()
        #expect(throws: SQLiteError.self) { try db.run("SELECT 1") }
    }

    @Test func optionalsBindAsNull() throws {
        let db = try database()
        let missing: Double? = nil
        try db.run(
            "INSERT INTO item (name, score, data, seen) VALUES (?, ?, ?, ?)",
            [SQLiteValue("a" as String?), SQLiteValue(missing), SQLiteValue(nil as Data?), SQLiteValue(nil as Date?)])
        #expect(
            try db.query("SELECT score IS NULL AND data IS NULL AND seen IS NULL FROM item") { $0.bool(0) } == [true])
    }

    @Test func cancellingTheTaskStopsAQueryMidway() async throws {
        let scan = Task {
            let db = try SQLiteDatabase.inMemory()
            var rows = 0
            // Five million rows; the task is cancelled after the first, so SQLite must stop early.
            _ = try db.query(
                "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n LIMIT 5000000) SELECT x FROM n"
            ) { row in
                rows += 1
                if rows == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                return row.int(0)
            }
            return rows
        }
        await #expect(throws: CancellationError.self) { try await scan.value }
    }

    @Test func manyDistinctStatementsStayUsable() throws {
        let db = try database()
        for count in 1...100 {
            let marks = Array(repeating: "?", count: count).joined(separator: ", ")
            let values = (1...count).map { SQLiteValue.integer(Int64($0)) }
            #expect(try db.query("SELECT count(*) FROM item WHERE id IN (\(marks))", values) { $0.int(0) } == [0])
        }
    }
}
