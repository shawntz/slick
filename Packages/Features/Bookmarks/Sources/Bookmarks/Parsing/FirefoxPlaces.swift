import Foundation

/// Reads Firefox's bookmarks from `places.sqlite`. ``parse(_:)`` is a pure function over the bytes
/// of a database image and touches no file.
///
/// `moz_bookmarks` holds the tree: `type` 1 is a bookmark, 2 a folder, 3 a separator, and `fk`
/// points at the row of `moz_places` that holds the link. The root's children are the menu,
/// toolbar, other, mobile and tags folders, told apart by their `guid`. The tags folder holds tags,
/// not bookmarks, so it is left out, and so are `place:` links, which are saved searches.
/// `dateAdded` is in microseconds since 1970.
nonisolated enum FirefoxPlaces {
    static let rootGUID = "root________"
    static let tagsGUID = "tags________"

    /// Every bookmark, in Firefox's order. An empty image has none. Throws
    /// ``BookmarkReadError/damaged`` for anything that is not a Firefox bookmarks database.
    static func parse(_ image: Data) throws(BookmarkReadError) -> [ParsedBookmark] {
        if image.isEmpty { return [] }
        let connection = try SQLiteConnection(image: image)
        return try read(connection)
    }

    /// The bookmark tables of a database file, copied into a small database image that
    /// ``parse(_:)`` reads. Opening the file folds its write-ahead log in, so the file must be a
    /// private copy the caller owns: see ``PrivateCopy``.
    static func bookmarkImage(ofCopyAt url: URL) throws(BookmarkReadError) -> Data {
        let connection = try SQLiteConnection(path: url.path(percentEncoded: false), readOnly: false)
        guard try connection.hasTable("moz_bookmarks"), try connection.hasTable("moz_places") else {
            throw .damaged
        }
        try connection.execute("ATTACH DATABASE ':memory:' AS slim")
        try connection.execute(
            """
            CREATE TABLE slim.moz_bookmarks AS
                SELECT id, type, fk, parent, position, title, dateAdded, guid FROM main.moz_bookmarks;
            CREATE TABLE slim.moz_places AS
                SELECT id, url, title FROM main.moz_places
                WHERE id IN (SELECT fk FROM main.moz_bookmarks WHERE fk IS NOT NULL);
            """)
        return try connection.serialize(schema: "slim")
    }

    /// One row of `moz_bookmarks` with its link.
    private struct Item {
        var id: Int64
        var type: Int64
        var parent: Int64
        var position: Int64
        var title: String?
        var dateAdded: Int64?
        var guid: String?
        var url: String?
        var pageTitle: String?
    }

    private static func read(_ connection: SQLiteConnection) throws(BookmarkReadError) -> [ParsedBookmark] {
        guard try connection.hasTable("moz_bookmarks"), try connection.hasTable("moz_places") else {
            throw .damaged
        }
        var items: [Item] = []
        try connection.query(
            """
            SELECT b.id, b.type, b.parent, b.position, b.title, b.dateAdded, b.guid, p.url, p.title
            FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id = b.fk
            """
        ) { row in
            guard let id = row.int(0) else { return }
            items.append(
                Item(
                    id: id, type: row.int(1) ?? 0, parent: row.int(2) ?? 0, position: row.int(3) ?? 0,
                    title: row.text(4), dateAdded: row.int(5), guid: row.text(6), url: row.text(7),
                    pageTitle: row.text(8)))
        }
        return tree(items)
    }

    /// Walks the tree from the root, in position order, with its own stack. A folder reached twice,
    /// as in a damaged file whose parents form a loop, is walked once.
    private static func tree(_ items: [Item]) -> [ParsedBookmark] {
        guard !items.isEmpty else { return [] }
        var children: [Int64: [Int]] = [:]
        for (index, item) in items.enumerated() { children[item.parent, default: []].append(index) }
        for key in children.keys {
            children[key]?.sort { (items[$0].position, items[$0].id) < (items[$1].position, items[$1].id) }
        }
        guard
            let root = items.first(where: { $0.guid == rootGUID })
                ?? items.first(where: { $0.parent == 0 && $0.type == 2 })
        else { return [] }

        struct Frame {
            var children: [Int]
            var index = 0
            var path: [String]
            var isBar = false
        }
        var visited: Set<Int64> = [root.id]
        var bookmarks: [ParsedBookmark] = []
        var stack = [Frame(children: children[root.id] ?? [], path: [])]
        while !stack.isEmpty, bookmarks.count < ParseLimits.maximumBookmarks {
            let top = stack.count - 1
            guard stack[top].index < stack[top].children.count else {
                stack.removeLast()
                continue
            }
            let item = items[stack[top].children[stack[top].index]]
            stack[top].index += 1
            let path = stack[top].path
            switch item.type {
            case 1:
                guard let url = item.url, !url.lowercased().hasPrefix("place:") else { continue }
                let title = item.title.flatMap { $0.isEmpty ? nil : $0 } ?? item.pageTitle ?? ""
                bookmarks.append(
                    ParsedBookmark(
                        title: title, url: url, folders: path, dateAdded: date(microseconds: item.dateAdded),
                        guid: item.guid, isOnBar: stack[top].isBar))
            case 2:
                guard item.guid != tagsGUID, visited.insert(item.id).inserted else { continue }
                let name = path.isEmpty ? Strings.Folders.firefoxRoot(guid: item.guid, title: item.title) : item.title
                let childPath = path.count < ParseLimits.maximumDepth ? path + [name ?? ""] : path
                let isBar = stack[top].isBar || (path.isEmpty && item.guid == "toolbar_____")
                stack.append(Frame(children: children[item.id] ?? [], path: childPath, isBar: isBar))
            default:
                continue
            }
        }
        return bookmarks
    }

    private static func date(microseconds: Int64?) -> Date? {
        guard let microseconds, microseconds > 0 else { return nil }
        let seconds = Double(microseconds) / 1_000_000
        guard seconds < 32_503_680_000 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
