import Foundation
import Testing

@testable import Bookmarks

@Suite("Safari bookmarks file", .timeLimit(.minutes(1)))
struct SafariParserTests {
    /// Written by hand in the layout Safari uses, as XML. Safari writes the same keys in binary.
    static let handWritten = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Children</key>
            <array>
                <dict>
                    <key>Title</key><string>History</string>
                    <key>WebBookmarkIdentifier</key><string>History</string>
                    <key>WebBookmarkType</key><string>WebBookmarkTypeProxy</string>
                    <key>WebBookmarkUUID</key><string>00000000-0000-4000-B000-000000000001</string>
                </dict>
                <dict>
                    <key>Children</key>
                    <array>
                        <dict>
                            <key>URIDictionary</key>
                            <dict><key>title</key><string>Project Board</string></dict>
                            <key>URLString</key><string>https://board.example.org/projects</string>
                            <key>WebBookmarkType</key><string>WebBookmarkTypeLeaf</string>
                            <key>WebBookmarkUUID</key><string>00000000-0000-4000-B000-000000000002</string>
                        </dict>
                    </array>
                    <key>Title</key><string>BookmarksBar</string>
                    <key>WebBookmarkType</key><string>WebBookmarkTypeList</string>
                    <key>WebBookmarkUUID</key><string>00000000-0000-4000-B000-000000000003</string>
                </dict>
                <dict>
                    <key>Children</key>
                    <array>
                        <dict>
                            <key>Children</key>
                            <array>
                                <dict>
                                    <key>URIDictionary</key>
                                    <dict><key>title</key><string>Rye Bread</string></dict>
                                    <key>URLString</key><string>https://recipes.example.net/bread</string>
                                    <key>WebBookmarkType</key><string>WebBookmarkTypeLeaf</string>
                                    <key>WebBookmarkUUID</key><string>00000000-0000-4000-B000-000000000004</string>
                                </dict>
                            </array>
                            <key>Title</key><string>Recipes</string>
                            <key>WebBookmarkType</key><string>WebBookmarkTypeList</string>
                            <key>WebBookmarkUUID</key><string>00000000-0000-4000-B000-000000000005</string>
                        </dict>
                    </array>
                    <key>Title</key><string>BookmarksMenu</string>
                    <key>WebBookmarkType</key><string>WebBookmarkTypeList</string>
                    <key>WebBookmarkUUID</key><string>00000000-0000-4000-B000-000000000006</string>
                </dict>
                <dict>
                    <key>Children</key>
                    <array>
                        <dict>
                            <key>ReadingList</key>
                            <dict>
                                <key>DateAdded</key><date>2026-11-01T08:00:00Z</date>
                                <key>PreviewText</key><string>A short preview.</string>
                            </dict>
                            <key>ReadingListNonSync</key>
                            <dict><key>neverFetchMetadata</key><false/></dict>
                            <key>URIDictionary</key>
                            <dict><key>title</key><string>A Long Read</string></dict>
                            <key>URLString</key><string>https://news.example.com/maps</string>
                            <key>WebBookmarkType</key><string>WebBookmarkTypeLeaf</string>
                            <key>WebBookmarkUUID</key><string>00000000-0000-4000-B000-000000000007</string>
                        </dict>
                    </array>
                    <key>Title</key><string>com.apple.ReadingList</string>
                    <key>WebBookmarkType</key><string>WebBookmarkTypeList</string>
                    <key>WebBookmarkUUID</key><string>00000000-0000-4000-B000-000000000008</string>
                </dict>
                <dict>
                    <key>URIDictionary</key>
                    <dict><key>title</key><string>Loose at the Top</string></dict>
                    <key>URLString</key><string>https://top.example.com/</string>
                    <key>WebBookmarkType</key><string>WebBookmarkTypeLeaf</string>
                    <key>WebBookmarkUUID</key><string>00000000-0000-4000-B000-000000000009</string>
                </dict>
            </array>
            <key>Title</key><string></string>
            <key>WebBookmarkFileVersion</key><integer>1</integer>
            <key>WebBookmarkType</key><string>WebBookmarkTypeList</string>
            <key>WebBookmarkUUID</key><string>00000000-0000-4000-B000-000000000010</string>
        </dict>
        </plist>
        """

    @Test func readsAFileAsSafariWritesIt() throws {
        let bookmarks = try SafariBookmarks.parse(Data(Self.handWritten.utf8))
        #expect(bookmarks.map(\.title) == ["Project Board", "Rye Bread", "A Long Read", "Loose at the Top"])
        #expect(bookmarks.map(\.folders) == [["Favorites"], ["Bookmarks Menu", "Recipes"], ["Reading List"], []])
        #expect(bookmarks.map(\.isReadingList) == [false, false, true, false])
        #expect(bookmarks.map(\.isOnBar) == [true, false, false, false])
        #expect(bookmarks[2].dateAdded == Date(timeIntervalSince1970: 1_793_520_000))
        #expect(bookmarks[0].guid == "00000000-0000-4000-B000-000000000002")
    }

    @Test func theBinaryFormReadsTheSame() throws {
        let object = try PropertyListSerialization.propertyList(from: Data(Self.handWritten.utf8), format: nil)
        let binary = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        #expect(try SafariBookmarks.parse(binary) == SafariBookmarks.parse(Data(Self.handWritten.utf8)))
        let written = try SafariBookmarks.parse(Samples.safari)
        #expect(written.map(\.title) == ["Project Board", "Rye Bread", "A Long Read"])
    }

    @Test func anEmptyFileHasNoBookmarks() throws {
        #expect(try SafariBookmarks.parse(Data()).isEmpty)
        let noChildren = try PropertyListSerialization.data(
            fromPropertyList: ["WebBookmarkType": "WebBookmarkTypeList", "Title": ""], format: .binary, options: 0)
        #expect(try SafariBookmarks.parse(noChildren).isEmpty)
    }

    @Test func aDamagedFileThrowsAndNeverCrashes() throws {
        let binary = Samples.safari
        let cases: [Data] = [
            binary.prefix(binary.count / 2), Data("bplist00".utf8), Data("<plist><dict>".utf8),
            Data("not a property list".utf8), Data(repeating: 0xFF, count: 128),
            try PropertyListSerialization.data(fromPropertyList: ["a", "b"], format: .binary, options: 0),
            try PropertyListSerialization.data(fromPropertyList: ["Other": "dictionary"], format: .binary, options: 0),
        ]
        for data in cases {
            #expect(throws: BookmarkReadError.damaged) { try SafariBookmarks.parse(data) }
        }
    }

    @Test func nodesOfTheWrongShapeAreSkipped() throws {
        let root: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList",
            "Children": [
                "a string",
                ["WebBookmarkType": "WebBookmarkTypeLeaf"],
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": 7],
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://untitled.example.com/"],
                [
                    "WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://odd.example.com/",
                    "URIDictionary": "x",
                ],
                [
                    "WebBookmarkType": "WebBookmarkTypeList", "Title": "Hidden", "ShouldOmitFromUI": true,
                    "Children": [
                        ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://hidden.example.com/"]
                    ],
                ],
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "No Children"],
                ["WebBookmarkType": "SomethingNew", "URLString": "https://new.example.com/"],
            ] as [Any],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        let bookmarks = try SafariBookmarks.parse(data)
        #expect(bookmarks.map(\.url) == ["https://untitled.example.com/", "https://odd.example.com/"])
        #expect(bookmarks.allSatisfy { $0.title.isEmpty })
    }

    @Test func deepFoldersAreReadAndDeeperOnesFailWithoutACrash() throws {
        func nested(_ depth: Int) -> FixtureNode {
            var node = FixtureNode.link("Deep", "https://deep.example.com/")
            for level in (0..<depth).reversed() { node = .folder("Level \(level)", [node]) }
            return node
        }
        let bookmarks = try SafariBookmarks.parse(BookmarkFixtures.safari(favorites: [nested(100)]))
        #expect(bookmarks.count == 1)
        #expect(bookmarks[0].folders.count == 101)
        #expect(bookmarks[0].folders.first == "Favorites")
        #expect(bookmarks[0].isOnBar)

        // Far past what the property list reader accepts: an error, not a crash. Written as text,
        // since writing it as a tree would recurse 5,000 levels in the test itself.
        var text = #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0">"#
        text += String(
            repeating: "<dict><key>WebBookmarkType</key><string>WebBookmarkTypeList</string>"
                + "<key>Children</key><array>", count: 5_000)
        text += String(repeating: "</array></dict>", count: 5_000) + "</plist>"
        #expect(throws: BookmarkReadError.damaged) { try SafariBookmarks.parse(Data(text.utf8)) }
    }
}
