import Foundation
import Testing

@testable import Bookmarks

@Suite("Chromium bookmarks file", .timeLimit(.minutes(1)))
struct ChromiumParserTests {
    /// Written by hand in the layout Chrome uses, not by the fixture writer, so a mistake in the
    /// writer cannot hide one in the parser.
    static let handWritten = """
        {
           "checksum": "0a1b2c3d4e5f60718293a4b5c6d7e8f9",
           "roots": {
              "bookmark_bar": {
                 "children": [ {
                    "date_added": "13345678901234567",
                    "date_last_used": "0",
                    "guid": "7d3c1a52-0000-4000-8000-000000000001",
                    "id": "5",
                    "meta_info": { "power_bookmark_meta": "" },
                    "name": "Team Wiki",
                    "type": "url",
                    "url": "https://wiki.example.org/"
                 }, {
                    "children": [ {
                       "date_added": "13345678901234999",
                       "guid": "7d3c1a52-0000-4000-8000-000000000002",
                       "id": "7",
                       "name": "Release Checklist",
                       "type": "url",
                       "url": "https://wiki.example.org/release"
                    } ],
                    "date_added": "13345678900000000",
                    "date_modified": "13345678901234999",
                    "guid": "7d3c1a52-0000-4000-9000-000000000003",
                    "id": "6",
                    "name": "Work",
                    "type": "folder"
                 } ],
                 "date_added": "13345678900000000",
                 "date_modified": "0",
                 "guid": "0bc5d13f-2cba-5d74-951f-3f233fe6c908",
                 "id": "1",
                 "name": "Bookmarks bar",
                 "type": "folder"
              },
              "other": {
                 "children": [ {
                    "date_added": "13345678905555555",
                    "guid": "7d3c1a52-0000-4000-8000-000000000004",
                    "id": "8",
                    "name": "Example Domain",
                    "type": "url",
                    "url": "https://example.com/"
                 } ],
                 "date_added": "13345678900000000",
                 "date_modified": "0",
                 "guid": "82b081ec-3dd3-529c-8475-ab6c344590dd",
                 "id": "2",
                 "name": "Other bookmarks",
                 "type": "folder"
              },
              "synced": {
                 "children": [ ],
                 "date_added": "13345678900000000",
                 "date_modified": "0",
                 "guid": "4cf2e351-0e85-532b-bb37-df045d8f8d0f",
                 "id": "3",
                 "name": "Mobile bookmarks",
                 "type": "folder"
              }
           },
           "sync_metadata": "",
           "version": 1
        }
        """

    @Test func readsAFileAsChromeWritesIt() throws {
        let bookmarks = try ChromiumBookmarks.parse(Data(Self.handWritten.utf8))
        #expect(bookmarks.map(\.title) == ["Team Wiki", "Release Checklist", "Example Domain"])
        #expect(bookmarks.map(\.folders) == [["Bookmarks bar"], ["Bookmarks bar", "Work"], ["Other bookmarks"]])
        #expect(bookmarks.map(\.isOnBar) == [true, true, false])
        #expect(bookmarks[0].guid == "7d3c1a52-0000-4000-8000-000000000001")
        // 13345678901234567 microseconds since 1601 is 2023-11-24 in 1970 seconds.
        let added = try #require(bookmarks[0].dateAdded)
        #expect(abs(added.timeIntervalSince1970 - (13_345_678_901.234567 - 11_644_473_600)) < 0.001)
    }

    @Test func anEmptyFileHasNoBookmarks() throws {
        #expect(try ChromiumBookmarks.parse(Data()).isEmpty)
        #expect(try ChromiumBookmarks.parse(Data(#"{"roots": {}}"#.utf8)).isEmpty)
        let emptyFolders = #"{"roots": {"bookmark_bar": {"type": "folder", "name": "Bar", "children": []}}}"#
        #expect(try ChromiumBookmarks.parse(Data(emptyFolders.utf8)).isEmpty)
    }

    @Test func aDamagedFileThrowsAndNeverCrashes() {
        let half = Data(Self.handWritten.utf8.prefix(Self.handWritten.utf8.count / 2))
        let cases: [Data] = [
            half, Data("not json".utf8), Data("   ".utf8), Data("[1, 2, 3]".utf8), Data(#"{"version": 1}"#.utf8),
            Data(#"{"roots": []}"#.utf8), Data([0xFF, 0xFE, 0x00, 0x01]), Data(repeating: 0, count: 64),
        ]
        for data in cases {
            #expect(throws: BookmarkReadError.damaged) { try ChromiumBookmarks.parse(data) }
        }
    }

    @Test func nodesOfTheWrongShapeAreSkipped() throws {
        let odd = """
            {"roots": {"bookmark_bar": {"type": "folder", "name": "Bar", "children": [
                {"type": "url", "name": 42, "url": "https://a.example.com/"},
                {"type": "url", "name": "No link"},
                {"type": "url", "name": "Link is a number", "url": 7},
                {"type": "folder", "name": "Children are a dictionary", "children": {"a": 1}},
                "a string where a node belongs",
                17,
                {"type": "separator", "name": "Unknown type"},
                {"name": "No type", "url": "https://b.example.com/"},
                {"type": "url", "name": "Fine", "url": "https://c.example.com/", "date_added": "nonsense"}
            ]}}}
            """
        let bookmarks = try ChromiumBookmarks.parse(Data(odd.utf8))
        #expect(bookmarks.map(\.url) == ["https://a.example.com/", "https://b.example.com/", "https://c.example.com/"])
        #expect(bookmarks.map(\.title) == ["", "No type", "Fine"])
        #expect(bookmarks.allSatisfy { $0.dateAdded == nil })
    }

    @Test func deepFoldersAreReadAndTheirPathIsBounded() throws {
        func nested(_ depth: Int) -> FixtureNode {
            var node = FixtureNode.link("Deep", "https://deep.example.com/")
            for level in (0..<depth).reversed() { node = .folder("Level \(level)", [node]) }
            return node
        }
        let deep = try ChromiumBookmarks.parse(BookmarkFixtures.chromium(bar: [nested(200)]))
        #expect(deep.count == 1)
        #expect(deep[0].folders.count == 201)
        #expect(deep[0].folders.last == "Level 199")

        // Ten thousand levels is past what the JSON reader accepts: an error, not a crash.
        var text = #"{"roots": {"bookmark_bar": "#
        for _ in 0..<10_000 { text += #"{"type": "folder", "name": "x", "children": ["# }
        text += String(repeating: "]}", count: 10_000) + "}}"
        #expect(throws: BookmarkReadError.damaged) { try ChromiumBookmarks.parse(Data(text.utf8)) }
    }

    @Test func operasExtraRootsAreReadButItsTrashIsNot() throws {
        let opera = """
            {"roots": {
                "bookmark_bar": {"type": "folder", "name": "Bookmarks bar", "children": []},
                "custom_root": {
                    "speedDial": {"type": "folder", "name": "Speed Dial", "children": [
                        {"type": "url", "name": "Dial", "url": "https://dial.example.com/"}]},
                    "trash": {"type": "folder", "name": "Trash", "children": [
                        {"type": "url", "name": "Thrown Away", "url": "https://trash.example.com/"}]},
                    "unsorted": {"type": "folder", "name": "Unsorted", "children": [
                        {"type": "url", "name": "Loose", "url": "https://loose.example.com/"}]}
                },
                "other": {"type": "folder", "name": "Other bookmarks", "children": []}
            }}
            """
        let bookmarks = try ChromiumBookmarks.parse(Data(opera.utf8))
        #expect(bookmarks.map(\.title) == ["Dial", "Loose"])
        #expect(bookmarks.map(\.folders) == [["Speed Dial"], ["Unsorted"]])
    }

    @Test func duplicatesNamelessLinksOddSchemesAndLongTitlesAllParse() throws {
        let long = String(repeating: "Long title ", count: 10_000)
        let data = Samples.chromium([
            ("Twice", "https://twice.example.com/"), ("Twice", "https://twice.example.com/"),
            (nil, "https://untitled.example.com/path/"),
            ("Bookmarklet", "javascript:alert(document.title)"), ("Local", "file:///tmp/example/notes.txt"),
            ("Flags", "chrome://flags"), (long, "https://long.example.com/"),
        ])
        let bookmarks = try ChromiumBookmarks.parse(data)
        #expect(bookmarks.count == 7, "the parser keeps everything; the index decides")
        #expect(bookmarks[2].title.isEmpty)
        #expect(bookmarks[6].title.count == long.count)
    }

    @Test func datesOutsideAnyBrowsersLifeAreDropped() {
        #expect(ChromiumBookmarks.date(chromiumMicroseconds: "0") == nil)
        #expect(ChromiumBookmarks.date(chromiumMicroseconds: "-5") == nil)
        #expect(ChromiumBookmarks.date(chromiumMicroseconds: "11644473600000000") == nil, "1970 exactly")
        #expect(ChromiumBookmarks.date(chromiumMicroseconds: "9999999999999999999999") == nil)
        #expect(ChromiumBookmarks.date(chromiumMicroseconds: "abc") == nil)
        #expect(ChromiumBookmarks.date(chromiumMicroseconds: NSNumber(value: 13_345_678_901_234_567)) != nil)
    }
}
