import Foundation

/// One bookmark as a parser found it, before it is cleaned up for display.
nonisolated struct ParsedBookmark: Hashable, Sendable {
    /// The title as the browser stored it. May be empty.
    var title: String
    /// The link as the browser stored it.
    var url: String
    /// The folders from the top, such as ["Bookmarks bar", "Work"]. The first is the browser's own
    /// top folder.
    var folders: [String]
    var dateAdded: Date?
    /// The browser's own ID for the bookmark, when it has one. Kept stable by the browser.
    var guid: String?
    /// True for an item of Safari's Reading List.
    var isReadingList: Bool
    /// True for a bookmark under the bookmarks bar, Safari's Favorites or Firefox's toolbar, which
    /// people use most.
    var isOnBar: Bool

    init(
        title: String, url: String, folders: [String], dateAdded: Date? = nil, guid: String? = nil,
        isReadingList: Bool = false, isOnBar: Bool = false
    ) {
        self.title = title
        self.url = url
        self.folders = folders
        self.dateAdded = dateAdded
        self.guid = guid
        self.isReadingList = isReadingList
        self.isOnBar = isOnBar
    }
}

/// Why a bookmarks file could not be read.
nonisolated enum BookmarkReadError: Error, Hashable, Sendable {
    /// The file is not in the format its browser writes, or is cut short.
    case damaged
    /// macOS refused to open the file.
    case accessDenied
    /// The file is larger than any bookmarks file should be.
    case tooLarge
    /// Anything else, such as a disk error.
    case unreadable

    var message: String {
        switch self {
        case .damaged: Strings.Problems.damaged
        case .accessDenied: Strings.Problems.accessDenied
        case .tooLarge: Strings.Problems.tooLarge
        case .unreadable: Strings.Problems.unreadable
        }
    }
}

/// Text from Foundation's JSON and property list readers, as native Swift text.
///
/// Those readers hand back Objective-C strings. Hashing or comparing one costs about ten times what
/// a native string costs, which at 50,000 bookmarks adds most of a second to every load.
nonisolated func nativeText(_ value: Any?) -> String? {
    guard var text = value as? String else { return nil }
    text.makeContiguousUTF8()
    return text
}

/// Limits that keep a hostile or broken file from costing too much.
nonisolated enum ParseLimits {
    /// Folders deeper than this are read, but their path keeps only the outermost levels. Walks use
    /// their own stack, so depth never grows the thread's stack.
    static let maximumDepth = 256
    /// More bookmarks than this in one file are left out.
    static let maximumBookmarks = 500_000
}
