import Foundation

/// Reads Safari's `Bookmarks.plist`, Reading List included. A pure function over the file's bytes.
///
/// The file is a property list, usually binary. Each node has a `WebBookmarkType`. A list is a
/// folder, with `Title` and `Children`. A leaf is a bookmark, with `URLString` and its title in
/// `URIDictionary.title`. A proxy stands for History and is not a bookmark. The top folders are
/// `BookmarksBar`, which Safari shows as Favorites, `BookmarksMenu` and `com.apple.ReadingList`,
/// whose leaves carry the date they were added in `ReadingList.DateAdded`.
nonisolated enum SafariBookmarks {
    static let readingListTitle = "com.apple.ReadingList"

    /// Every bookmark and Reading List item, in Safari's order. An empty file has none. Throws
    /// ``BookmarkReadError/damaged`` for anything that is not Safari's bookmarks file.
    static func parse(_ data: Data) throws(BookmarkReadError) -> [ParsedBookmark] {
        if data.isEmpty { return [] }
        guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let root = object as? [String: Any], root["WebBookmarkType"] is String || root["Children"] != nil
        else { throw .damaged }
        guard let children = root["Children"] as? [Any] else { return [] }

        struct Frame {
            var children: [Any]
            var index = 0
            var path: [String]
            var isReadingList: Bool
            var isBar = false
        }
        var bookmarks: [ParsedBookmark] = []
        var stack = [Frame(children: children, path: [], isReadingList: false)]
        while !stack.isEmpty, bookmarks.count < ParseLimits.maximumBookmarks {
            let top = stack.count - 1
            guard stack[top].index < stack[top].children.count else {
                stack.removeLast()
                continue
            }
            let child = stack[top].children[stack[top].index]
            stack[top].index += 1
            guard let node = child as? [String: Any], node["ShouldOmitFromUI"] as? Bool != true else { continue }
            let frame = stack[top]
            switch node["WebBookmarkType"] as? String {
            case "WebBookmarkTypeLeaf":
                guard let url = nativeText(node["URLString"]) else { continue }
                let title = nativeText((node["URIDictionary"] as? [String: Any])?["title"]) ?? nativeText(node["Title"])
                let readingList = node["ReadingList"] as? [String: Any]
                bookmarks.append(
                    ParsedBookmark(
                        title: title ?? "", url: url, folders: frame.path,
                        dateAdded: readingList?["DateAdded"] as? Date, guid: nativeText(node["WebBookmarkUUID"]),
                        isReadingList: frame.isReadingList, isOnBar: frame.isBar))
            case "WebBookmarkTypeList":
                let title = nativeText(node["Title"]) ?? ""
                let isTop = frame.path.isEmpty && top == 0
                let isReadingList = frame.isReadingList || (isTop && title == readingListTitle)
                let name = isTop ? Strings.Folders.safariRoot(title) : title
                let path = frame.path.count < ParseLimits.maximumDepth ? frame.path + [name] : frame.path
                stack.append(
                    Frame(
                        children: node["Children"] as? [Any] ?? [], path: path, isReadingList: isReadingList,
                        isBar: frame.isBar || (isTop && title == "BookmarksBar")))
            default:
                // Proxies such as History, and anything unknown.
                continue
            }
        }
        return bookmarks
    }
}
