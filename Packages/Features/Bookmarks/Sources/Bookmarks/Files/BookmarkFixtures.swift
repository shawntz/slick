import Foundation

/// A synthetic bookmark tree, written out in each browser's format by ``BookmarkFixtures``. The
/// isolated service serves files made this way, and tests build odd files with it.
nonisolated enum FixtureNode: Sendable {
    case link(_ title: String?, _ url: String, guid: String? = nil, added: Date? = nil)
    indirect case folder(_ name: String, _ children: [FixtureNode])
}

/// Writes synthetic bookmark files in the formats the parsers read, as each browser lays them out.
nonisolated enum BookmarkFixtures {
    // MARK: - Chromium

    /// A Chromium `Bookmarks` file with the three usual top folders.
    static func chromium(bar: [FixtureNode], other: [FixtureNode] = [], synced: [FixtureNode] = []) -> Data {
        var nextID = 1
        func node(_ fixture: FixtureNode) -> [String: Any] {
            nextID += 1
            switch fixture {
            case .link(let title, let url, let guid, let added):
                var node: [String: Any] = [
                    "id": String(nextID), "type": "url", "url": url,
                    "guid": guid ?? String(format: "00000000-0000-4000-8000-%012d", nextID),
                    "date_added": chromiumDate(added),
                ]
                if let title { node["name"] = title }
                return node
            case .folder(let name, let children):
                return [
                    "id": String(nextID), "type": "folder", "name": name, "children": children.map(node),
                    "guid": String(format: "00000000-0000-4000-9000-%012d", nextID), "date_added": chromiumDate(nil),
                    "date_modified": "0",
                ]
            }
        }
        func root(_ name: String, _ children: [FixtureNode]) -> [String: Any] {
            nextID += 1
            return [
                "id": String(nextID), "type": "folder", "name": name, "children": children.map(node),
                "date_added": chromiumDate(nil), "date_modified": "0",
                "guid": String(format: "00000000-0000-4000-a000-%012d", nextID),
            ]
        }
        let file: [String: Any] = [
            "checksum": "00000000000000000000000000000000",
            "roots": [
                "bookmark_bar": root("Bookmarks bar", bar), "other": root("Other bookmarks", other),
                "synced": root("Mobile bookmarks", synced),
            ],
            "version": 1,
        ]
        return (try? JSONSerialization.data(withJSONObject: file, options: [.sortedKeys])) ?? Data()
    }

    /// A date as Chromium stores it: microseconds since 1601, as text.
    static func chromiumDate(_ date: Date?) -> String {
        let seconds = (date ?? Date(timeIntervalSince1970: 1_700_000_000)).timeIntervalSince1970 + 11_644_473_600
        return String(Int64(seconds * 1_000_000))
    }

    // MARK: - Safari

    /// Safari's `Bookmarks.plist`, binary, with Favorites, the Bookmarks Menu and the Reading List.
    static func safari(favorites: [FixtureNode], menu: [FixtureNode] = [], readingList: [FixtureNode] = []) -> Data {
        var nextID = 0
        func uuid() -> String {
            nextID += 1
            return String(format: "00000000-0000-4000-B000-%012d", nextID)
        }
        func node(_ fixture: FixtureNode, inReadingList: Bool) -> [String: Any] {
            switch fixture {
            case .link(let title, let url, let guid, let added):
                var node: [String: Any] = [
                    "WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": url, "WebBookmarkUUID": guid ?? uuid(),
                    "URIDictionary": title.map { ["title": $0] } ?? [:],
                ]
                if inReadingList {
                    node["ReadingList"] = ["DateAdded": added ?? Date(timeIntervalSince1970: 1_700_000_000)]
                }
                return node
            case .folder(let name, let children):
                return [
                    "WebBookmarkType": "WebBookmarkTypeList", "Title": name, "WebBookmarkUUID": uuid(),
                    "Children": children.map { node($0, inReadingList: inReadingList) },
                ]
            }
        }
        func top(_ title: String, _ children: [FixtureNode], readingList: Bool = false) -> [String: Any] {
            [
                "WebBookmarkType": "WebBookmarkTypeList", "Title": title, "WebBookmarkUUID": uuid(),
                "Children": children.map { node($0, inReadingList: readingList) },
            ]
        }
        let root: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkFileVersion": 1, "Title": "",
            "WebBookmarkUUID": uuid(),
            "Children": [
                ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History", "WebBookmarkIdentifier": "History"],
                top("BookmarksBar", favorites), top("BookmarksMenu", menu),
                top(SafariBookmarks.readingListTitle, readingList, readingList: true),
            ],
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)) ?? Data()
    }

    // MARK: - Firefox

    /// The tables of `places.sqlite` the parser reads, with the columns Firefox defines.
    static let firefoxSchema = """
        CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, rev_host LONGVARCHAR,
            visit_count INTEGER DEFAULT 0, hidden INTEGER DEFAULT 0 NOT NULL, typed INTEGER DEFAULT 0 NOT NULL,
            frecency INTEGER DEFAULT -1 NOT NULL, last_visit_date INTEGER, guid TEXT,
            foreign_count INTEGER DEFAULT 0 NOT NULL, url_hash INTEGER DEFAULT 0 NOT NULL, description TEXT,
            preview_image_url TEXT, origin_id INTEGER, site_name TEXT);
        CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER DEFAULT NULL, parent INTEGER,
            position INTEGER, title LONGVARCHAR, keyword_id INTEGER, folder_type TEXT, dateAdded INTEGER,
            lastModified INTEGER, guid TEXT, syncStatus INTEGER NOT NULL DEFAULT 0,
            syncChangeCounter INTEGER NOT NULL DEFAULT 1);
        CREATE INDEX moz_bookmarks_itemindex ON moz_bookmarks (fk, type);
        CREATE INDEX moz_bookmarks_parentindex ON moz_bookmarks (parent, position);
        """

    /// A Firefox database with the usual root folders, as the bytes of its file. Tags name links
    /// that the tags folder holds, which are not bookmarks.
    static func firefox(
        menu: [FixtureNode] = [], toolbar: [FixtureNode] = [], other: [FixtureNode] = [],
        mobile: [FixtureNode] = [], tags: [(tag: String, url: String)] = []
    ) -> Data {
        (try? firefoxImage(menu: menu, toolbar: toolbar, other: other, mobile: mobile, tags: tags)) ?? Data()
    }

    private static func firefoxImage(
        menu: [FixtureNode], toolbar: [FixtureNode], other: [FixtureNode], mobile: [FixtureNode],
        tags: [(tag: String, url: String)]
    ) throws(BookmarkReadError) -> Data {
        let database = try SQLiteConnection()
        try database.execute(firefoxSchema)
        var nextID: Int64 = 1
        var nextPlace: Int64 = 0
        var places: [String: Int64] = [:]
        func place(_ url: String, title: String?) throws(BookmarkReadError) -> Int64 {
            if let existing = places[url] { return existing }
            nextPlace += 1
            places[url] = nextPlace
            try database.run(
                "INSERT INTO moz_places (id, url, title, guid) VALUES (?, ?, ?, ?)",
                [.int(nextPlace), .text(url), title.map { .text($0) } ?? .null, .text("place\(nextPlace)")])
            return nextPlace
        }
        func insert(_ type: Int64, parent: Int64, position: Int, title: String?, guid: String, fk: Int64? = nil)
            throws(BookmarkReadError) -> Int64
        {
            nextID += 1
            try database.run(
                "INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, dateAdded, guid)"
                    + " VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                [
                    .int(nextID), .int(type), fk.map { .int($0) } ?? .null, .int(parent), .int(Int64(position)),
                    title.map { .text($0) } ?? .null, .int(1_700_000_000_000_000), .text(guid),
                ])
            return nextID
        }
        func add(_ nodes: [FixtureNode], parent: Int64) throws(BookmarkReadError) {
            for (position, node) in nodes.enumerated() {
                switch node {
                case .link(let title, let url, let guid, _):
                    let fk = try place(url, title: title)
                    _ = try insert(
                        1, parent: parent, position: position, title: title, guid: guid ?? "bm\(nextID + 1)", fk: fk)
                case .folder(let name, let children):
                    let folder = try insert(
                        2, parent: parent, position: position, title: name, guid: "folder\(nextID + 1)")
                    try add(children, parent: folder)
                }
            }
        }
        try database.run(
            "INSERT INTO moz_bookmarks (id, type, parent, position, title, guid) VALUES (1, 2, 0, 0, '', ?)",
            [.text(FirefoxPlaces.rootGUID)])
        let roots: [(guid: String, title: String, nodes: [FixtureNode])] = [
            ("menu________", "menu", menu), ("toolbar_____", "toolbar", toolbar),
            (FirefoxPlaces.tagsGUID, "tags", []), ("unfiled_____", "unfiled", other),
            ("mobile______", "mobile", mobile),
        ]
        var tagsFolder: Int64 = 0
        for (position, root) in roots.enumerated() {
            let id = try insert(2, parent: 1, position: position, title: root.title, guid: root.guid)
            if root.guid == FirefoxPlaces.tagsGUID { tagsFolder = id }
            try add(root.nodes, parent: id)
        }
        for (position, tag) in tags.enumerated() {
            let folder = try insert(2, parent: tagsFolder, position: position, title: tag.tag, guid: "tag\(nextID + 1)")
            _ = try insert(
                1, parent: folder, position: 0, title: nil, guid: "tagged\(nextID + 1)",
                fk: try place(tag.url, title: nil))
        }
        return try database.serialize(schema: "main")
    }
}
