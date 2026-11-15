import CoreBridge
import Foundation
import Kit

/// What a file row carries for its actions. Small, so a remembered row stays well under 1 KB.
nonisolated struct FileItem: Codable, Hashable, Sendable {
    /// A folder, including a package such as an app.
    var isFolder: Bool
    /// A package, such as an app or a document package, shown as one item.
    var isPackage = false
}

/// Builds the rows for files and folders. Rows are plain data, built on the search queue.
nonisolated enum FileRows {
    /// The namespace of every file row: `file:<absolute path>`.
    static let namespace = "file"

    /// How a set of rows is shown.
    struct Style: Sendable {
        /// The home folder, shown as "~".
        var home: String
        /// Folder completions start with "/" rather than "~", as when the user typed an absolute
        /// path.
        var absoluteCompletions = false
        /// Rows show the modification date, as on the Search Files page.
        var showsDate = false
    }

    static func id(for path: String) -> ItemID {
        ItemID(namespace, path)
    }

    /// The row for one index entry.
    static func row(
        path: String, flags: FileEntryFlags, modified: UInt32?, highlights: [Range<Int>], style: Style
    ) -> Row {
        let isFolder = flags.contains(.directory)
        let isPackage = flags.contains(.package)
        let url = URL(filePath: path, directoryHint: isFolder ? .isDirectory : .notDirectory)
        var completion: String?
        if isFolder && !isPackage {
            let shown = style.absoluteCompletions ? path : Paths.display(path, home: style.home)
            completion = shown == "/" ? shown : shown + "/"
        }
        var accessories: [Accessory] = []
        if style.showsDate, let modified, modified > 0 {
            accessories.append(.date(Date(timeIntervalSince1970: TimeInterval(modified))))
        }
        let title = title(for: Paths.name(of: path))
        let placeholder = title == Strings.Root.blankName && Paths.name(of: path) != title
        return Row(
            id: id(for: path), title: title,
            subtitle: oneLine(Paths.display(Paths.parent(of: path), home: style.home)), icon: .file(path: path),
            accessories: accessories, payload: Payload(FileItem(isFolder: isFolder, isPackage: isPackage)),
            completion: completion, quickLookURL: url, titleHighlights: placeholder ? [] : highlights,
            represents: .files([url]))
    }

    /// The item a row stands for. A row rebuilt from a snapshot keeps its payload; one without
    /// counts as a file.
    static func item(of row: Row) -> FileItem {
        (try? row.payload?.decode(FileItem.self)) ?? FileItem(isFolder: false)
    }

    /// The row's file URL, from its ID alone.
    static func url(of row: Row) -> URL {
        URL(filePath: row.id.key, directoryHint: item(of: row).isFolder ? .isDirectory : .notDirectory)
    }

    /// Text on one line that draws in the order it is stored: line breaks, other control
    /// characters and the line and paragraph separators become spaces, and the controls that
    /// reorder text, such as a right-to-left override, become U+FFFD. Each is one UTF-16 unit and
    /// is replaced by one, so highlight ranges stay right. An override in a file name can make
    /// "photo\u{202E}gpj.app" read as an image, so it is shown, never obeyed.
    static func oneLine(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { replacement(for: $0) != nil }) else { return text }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            scalars.append(replacement(for: scalar) ?? scalar)
        }
        return String(scalars)
    }

    private static func replacement(for scalar: Unicode.Scalar) -> Unicode.Scalar? {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: return " "
        default: break
        }
        let value = scalar.value
        if (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value) { return "\u{FFFD}" }
        return nil
    }

    /// A row's title: the name on one line. A name with nothing visible, such as a single space,
    /// shows as a placeholder rather than as an empty title.
    static func title(for name: String) -> String {
        let line = oneLine(name)
        let visible = line.unicodeScalars.contains { scalar in
            !scalar.properties.isWhitespace && !scalar.properties.isDefaultIgnorableCodePoint
        }
        return visible ? line : Strings.Root.blankName
    }

    /// The heading for a folder query: the folder being listed, as typed.
    static func folderTitle(for query: String) -> String {
        guard let slash = query.lastIndex(of: "/") else { return query }
        let folder = String(query[..<slash])
        if folder.isEmpty { return "/" }
        return folder
    }
}
