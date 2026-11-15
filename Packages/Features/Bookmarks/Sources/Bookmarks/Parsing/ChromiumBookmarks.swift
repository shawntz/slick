import Foundation

/// Reads the `Bookmarks` file that Chrome, Brave, Edge, Vivaldi, Opera and Chromium keep in each
/// profile folder. A pure function over the file's bytes.
///
/// The file is JSON: `roots` holds the top folders, usually `bookmark_bar`, `other` and `synced`.
/// Each node has a `type` of `url` or `folder`, a `name`, a `guid`, and `date_added` in
/// microseconds since 1601. Folders hold `children`. Opera adds a `custom_root` that holds more top
/// folders, one of them its trash, which is left out.
nonisolated enum ChromiumBookmarks {
    /// The top folders in the order browsers show them. Others follow in name order.
    private static let rootOrder = ["bookmark_bar", "other", "synced"]

    /// Every bookmark in the file, in the browser's order. An empty file has none. Throws
    /// ``BookmarkReadError/damaged`` for anything that is not a bookmarks file.
    static func parse(_ data: Data) throws(BookmarkReadError) -> [ParsedBookmark] {
        if data.isEmpty { return [] }
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let file = object as? [String: Any], let roots = file["roots"] as? [String: Any]
        else { throw .damaged }
        var walk = Walk()
        for (key, value) in ordered(roots) {
            guard let node = value as? [String: Any] else { continue }
            if isNode(node) {
                walk.visit(
                    folder: node, name: name(of: node) ?? Strings.Folders.chromiumRoot(key),
                    isBar: key == "bookmark_bar")
            } else {
                // A container of more top folders.
                for (innerKey, innerValue) in ordered(node) where innerKey.lowercased() != "trash" {
                    guard let inner = innerValue as? [String: Any], isNode(inner) else { continue }
                    walk.visit(folder: inner, name: name(of: inner) ?? innerKey, isBar: false)
                }
            }
        }
        return walk.bookmarks
    }

    /// Microseconds since 1 January 1601, as Chromium stores dates, as a date. Nil for zero, for
    /// text that is not a number and for dates before 1970 or far in the future.
    static func date(chromiumMicroseconds value: Any?) -> Date? {
        let micros: Double? =
            switch value {
            case let text as String: Double(text)
            case let number as NSNumber: number.doubleValue
            default: nil
            }
        guard let micros, micros.isFinite, micros > 0 else { return nil }
        let seconds = micros / 1_000_000 - 11_644_473_600
        guard seconds > 0, seconds < 32_503_680_000 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// The pairs in the browser's root order, then by key, so the result never depends on hashing.
    private static func ordered(_ dictionary: [String: Any]) -> [(String, Any)] {
        let known = rootOrder.compactMap { key in dictionary[key].map { (key, $0) } }
        let rest = dictionary.filter { !rootOrder.contains($0.key) }.sorted { $0.key < $1.key }
        return known + rest.map { ($0.key, $0.value) }
    }

    private static func isNode(_ node: [String: Any]) -> Bool {
        node["type"] is String || node["children"] is [Any] || node["url"] is String
    }

    private static func name(of node: [String: Any]) -> String? {
        guard let name = nativeText(node["name"]), !name.isEmpty else { return nil }
        return name
    }

    /// A depth-first walk with its own stack, so a deep file cannot overflow the thread's stack.
    private struct Walk {
        private struct Frame {
            var children: [Any]
            var index = 0
            var path: [String]
        }

        var bookmarks: [ParsedBookmark] = []

        mutating func visit(folder: [String: Any], name: String, isBar: Bool) {
            var stack = [Frame(children: folder["children"] as? [Any] ?? [], path: [name])]
            while !stack.isEmpty, bookmarks.count < ParseLimits.maximumBookmarks {
                let top = stack.count - 1
                guard stack[top].index < stack[top].children.count else {
                    stack.removeLast()
                    continue
                }
                let child = stack[top].children[stack[top].index]
                stack[top].index += 1
                guard let node = child as? [String: Any] else { continue }
                let path = stack[top].path
                let type = node["type"] as? String
                if type == "url" || (type == nil && node["url"] is String) {
                    guard let url = nativeText(node["url"]) else { continue }
                    bookmarks.append(
                        ParsedBookmark(
                            title: nativeText(node["name"]) ?? "", url: url, folders: path,
                            dateAdded: ChromiumBookmarks.date(chromiumMicroseconds: node["date_added"]),
                            guid: nativeText(node["guid"]), isOnBar: isBar))
                } else if type == "folder" || (type == nil && node["children"] is [Any]) {
                    let name = nativeText(node["name"]) ?? ""
                    let childPath = path.count < ParseLimits.maximumDepth ? path + [name] : path
                    stack.append(Frame(children: node["children"] as? [Any] ?? [], path: childPath))
                }
            }
        }
    }
}
