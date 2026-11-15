import Foundation
import SQLite3
import Testing

@testable import Bookmarks

@Suite("Firefox places database", .timeLimit(.minutes(1)))
struct FirefoxParserTests {
    /// A database built by hand with SQL in the layout Firefox uses, not by the fixture writer.
    static func handBuilt(extra: String = "") throws -> Data {
        let database = try SQLiteConnection()
        try database.execute(BookmarkFixtures.firefoxSchema)
        try database.execute(
            """
            INSERT INTO moz_places (id, url, title, guid) VALUES
                (1, 'https://library.example.org/', 'Library Catalog page', 'p1'),
                (2, 'https://status.example.com/', 'Status', 'p2'),
                (3, 'place:sort=8&maxResults=10', NULL, 'p3'),
                (4, 'https://tagged.example.net/', 'Tagged page', 'p4'),
                (5, 'https://untitled.example.com/a/b', 'Page title only', 'p5');
            INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, dateAdded, guid) VALUES
                (1, 2, NULL, 0, 0, '', 1700000000000000, 'root________'),
                (2, 2, NULL, 1, 0, 'menu', 1700000000000000, 'menu________'),
                (3, 2, NULL, 1, 1, 'toolbar', 1700000000000000, 'toolbar_____'),
                (4, 2, NULL, 1, 2, 'tags', 1700000000000000, 'tags________'),
                (5, 2, NULL, 1, 3, 'unfiled', 1700000000000000, 'unfiled_____'),
                (6, 2, NULL, 1, 4, 'mobile', 1700000000000000, 'mobile______'),
                (10, 1, 1, 2, 1, 'Library Catalog', 1700000000123456, 'ff-library'),
                (11, 3, NULL, 2, 0, NULL, 1700000000000000, 'ff-separator'),
                (12, 2, NULL, 3, 0, 'Daily', 1700000000000000, 'ff-daily'),
                (13, 1, 2, 12, 0, 'Status Page', 1700000000000000, 'ff-status'),
                (14, 1, 3, 3, 1, 'Most Visited', 1700000000000000, 'ff-smart'),
                (15, 2, NULL, 4, 0, 'reading', 1700000000000000, 'ff-tag'),
                (16, 1, 4, 15, 0, NULL, 1700000000000000, 'ff-tagged'),
                (17, 1, 5, 5, 0, NULL, 1700000000000000, 'ff-untitled');
            """ + extra)
        return try database.serialize(schema: "main")
    }

    @Test func readsADatabaseAsFirefoxWritesIt() throws {
        let bookmarks = try FirefoxPlaces.parse(try Self.handBuilt())
        #expect(bookmarks.map(\.title) == ["Library Catalog", "Status Page", "Page title only"])
        #expect(
            bookmarks.map(\.folders) == [["Bookmarks Menu"], ["Bookmarks Toolbar", "Daily"], ["Other Bookmarks"]])
        #expect(bookmarks.map(\.isOnBar) == [false, true, false])
        #expect(bookmarks[0].guid == "ff-library")
        #expect(bookmarks[0].dateAdded == Date(timeIntervalSince1970: 1_700_000_000.123456))
        #expect(!bookmarks.contains { $0.url.hasPrefix("place:") }, "saved searches are not bookmarks")
        #expect(!bookmarks.contains { $0.url == "https://tagged.example.net/" }, "tags are not bookmarks")
    }

    @Test func theFixtureWriterMatchesTheHandBuiltLayout() throws {
        let bookmarks = try FirefoxPlaces.parse(Samples.firefox)
        #expect(bookmarks.map(\.title) == ["Library Catalog", "Status Page"])
        #expect(bookmarks.map(\.folders) == [["Bookmarks Menu"], ["Bookmarks Toolbar"]])
    }

    @Test func aDatabaseWrittenInLogModeIsRead() throws {
        var image = try Self.handBuilt()
        image[18] = 2
        image[19] = 2
        #expect(try FirefoxPlaces.parse(image).count == 3)
    }

    @Test func anEmptyFileHasNoBookmarks() throws {
        #expect(try FirefoxPlaces.parse(Data()).isEmpty)
        let database = try SQLiteConnection()
        try database.execute(BookmarkFixtures.firefoxSchema)
        #expect(try FirefoxPlaces.parse(try database.serialize(schema: "main")).isEmpty)
    }

    @Test func aDamagedFileThrowsAndNeverCrashes() throws {
        let good = try Self.handBuilt()
        var scrambled = good
        for index in stride(from: 100, to: scrambled.count, by: 7) { scrambled[index] ^= 0x5A }
        let other = try SQLiteConnection()
        try other.execute("CREATE TABLE other (x INTEGER); INSERT INTO other VALUES (1);")
        let noTables = try other.serialize(schema: "main")
        let cases: [Data] = [
            Data("SQLite format 3\0".utf8) + Data(repeating: 0xAB, count: 4_000), good.prefix(good.count / 2),
            Data("not a database at all, just words".utf8), Data(repeating: 0, count: 512), scrambled, noTables,
        ]
        for data in cases {
            #expect(throws: BookmarkReadError.self) { try FirefoxPlaces.parse(data) }
        }
    }

    @Test func aViewInPlaceOfATableIsRefused() throws {
        let database = try SQLiteConnection()
        try database.execute(
            """
            CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT);
            CREATE TABLE real (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER,
                title TEXT, dateAdded INTEGER, guid TEXT);
            CREATE VIEW moz_bookmarks AS SELECT * FROM real;
            """)
        #expect(throws: BookmarkReadError.damaged) { try FirefoxPlaces.parse(try database.serialize(schema: "main")) }
    }

    @Test func loopsInTheTreeEndAndDeepFoldersAreBounded() throws {
        // Two folders that name each other as parent, hanging off the menu, and a chain 300 deep.
        var chain = ""
        for level in 0..<300 {
            let parent = level == 0 ? 2 : 1_000 + level - 1
            chain += ",(\(1_000 + level), 2, NULL, \(parent), 0, 'Level \(level)', 0, 'chain\(level)')"
        }
        let extra = """
            ;
            INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, dateAdded, guid) VALUES
                (20, 2, NULL, 21, 0, 'Loop A', 0, 'loop-a'),
                (21, 2, NULL, 20, 0, 'Loop B', 0, 'loop-b'),
                (22, 1, 2, 20, 1, 'In the Loop', 0, 'in-loop'),
                (23, 2, NULL, 23, 0, 'Own Parent', 0, 'own')\(chain),
                (2000, 1, 1, 1299, 0, 'Bottom', 0, 'bottom');
            """
        let bookmarks = try FirefoxPlaces.parse(try Self.handBuilt(extra: extra))
        #expect(!bookmarks.contains { $0.title == "In the Loop" }, "unreachable from the root")
        let bottom = try #require(bookmarks.first { $0.title == "Bottom" })
        #expect(bottom.folders.count == ParseLimits.maximumDepth)
    }

    @Test func duplicatesUntitledLinksAndOddSchemesParse() throws {
        let data = BookmarkFixtures.firefox(
            menu: [
                .link("Twice", "https://twice.example.com/"), .link("Twice", "https://twice.example.com/"),
                .link(nil, "https://no-title.example.com/"), .link("Run Me", "javascript:void(0)"),
                .link("Local", "file:///tmp/example/report.pdf"),
                .link(String(repeating: "x", count: 100_000), "https://long.example.com/"),
            ])
        let bookmarks = try FirefoxPlaces.parse(data)
        #expect(bookmarks.count == 6)
        #expect(bookmarks[2].title.isEmpty)
        #expect(bookmarks[5].title.count == 100_000)
    }
}

@Suite("Reading Firefox without disturbing it", .timeLimit(.minutes(1)))
struct FirefoxCopyTests {
    /// A database in log mode with a connection that stays open and never folds its log in, as a
    /// running Firefox holds it. Rows written last sit only in the log.
    nonisolated final class RunningDatabase {
        let folder = Samples.temporaryFolder()
        var url: URL { folder.appending(path: "places.sqlite") }
        private var handle: OpaquePointer?

        init() throws {
            guard sqlite3_open(url.path(percentEncoded: false), &handle) == SQLITE_OK else {
                throw BookmarkReadError.unreadable
            }
            try run("PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;")
            try run(BookmarkFixtures.firefoxSchema)
            try run(
                """
                INSERT INTO moz_bookmarks (id, type, parent, position, title, guid) VALUES
                    (1, 2, 0, 0, '', 'root________'), (2, 2, 1, 0, 'menu', 'menu________');
                """)
        }

        deinit {
            sqlite3_close(handle)
            try? FileManager.default.removeItem(at: folder)
        }

        func add(_ id: Int, title: String) throws {
            try run(
                """
                INSERT INTO moz_places (id, url, title) VALUES (\(id), 'https://site\(id).example.com/', NULL);
                INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, guid)
                    VALUES (\(100 + id), 1, \(id), 2, \(id), '\(title)', 'g\(id)');
                """)
        }

        func run(_ sql: String) throws {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw BookmarkReadError.unreadable }
        }
    }

    @Test func recentChangesInTheLogAreReadAndTheBrowserKeepsWriting() throws {
        let running = try RunningDatabase()
        try running.add(1, title: "First")
        try running.add(2, title: "Second")
        let log = URL(filePath: running.url.path(percentEncoded: false) + "-wal")
        #expect(FileManager.default.fileExists(atPath: log.path(percentEncoded: false)))
        let scratch = Samples.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let image = try PrivateCopy.firefoxBookmarkImage(of: running.url, scratchRoot: scratch)
        #expect(try FirefoxPlaces.parse(image).map(\.title) == ["First", "Second"])
        #expect(image.count < 64 * 1_024, "only the bookmark tables travel")
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path(percentEncoded: false)).isEmpty)

        // The browser's connection still writes, and the next read sees it.
        try running.add(3, title: "Third")
        let again = try PrivateCopy.firefoxBookmarkImage(of: running.url, scratchRoot: scratch)
        #expect(try FirefoxPlaces.parse(again).map(\.title) == ["First", "Second", "Third"])
    }

    @Test func aLinkInPlaceOfTheDatabaseIsNotFollowed() throws {
        let running = try RunningDatabase()
        let folder = Samples.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let link = folder.appending(path: "places.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: running.url)
        #expect(throws: BookmarkReadError.unreadable) {
            try PrivateCopy.firefoxBookmarkImage(of: link, scratchRoot: folder.appending(path: "scratch"))
        }
    }

    @Test func aMissingDatabaseIsAnError() {
        let folder = Samples.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: BookmarkReadError.self) {
            try PrivateCopy.firefoxBookmarkImage(of: folder.appending(path: "places.sqlite"), scratchRoot: folder)
        }
    }
}
