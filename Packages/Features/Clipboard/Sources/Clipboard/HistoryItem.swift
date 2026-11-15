import Foundation
import Kit

/// One item as a row shows it: everything but the full content, so a page of rows stays small.
nonisolated struct ItemSummary: Hashable, Sendable {
    /// The item's place in the history. Higher is newer. Moving an item to the top gives it a new one.
    var order: Int64
    var key: ItemKey
    var kind: ClipKind
    /// The first few hundred characters of the text, link, color or file paths.
    var preview: String?
    /// The whole text when it is short, for what the row stands for. Nil for long text and images.
    var shortText: String?
    /// The stored image and its thumbnail, for images.
    var imageURL: URL?
    var thumbnailURL: URL?
    var pixelWidth: Int?
    var pixelHeight: Int?
    /// The text's UTF-8 bytes or the image's bytes.
    var byteCount: Int
    /// The bundle ID of the app that copied it.
    var source: String?
    /// When it was last copied or used from the history.
    var copied: Date
    var isPinned: Bool

    /// The files of a files item, when the row knows them all.
    var fileURLs: [URL] {
        guard kind == .files, let paths = shortText ?? preview else { return [] }
        return paths.split(separator: "\n").map { URL(filePath: String($0)) }
    }

    /// The link of a link item.
    var link: URL? {
        guard kind == .link, let text = shortText ?? preview else { return nil }
        return URL(string: text)
    }
}

/// One item with its whole content, for the detail pane.
nonisolated struct ItemDetail: Sendable {
    var summary: ItemSummary
    /// The whole text, link, color or file list. Nil for images.
    var text: String?
    var rtf: Data?
    var imageType: String?
    var firstCopied: Date
    var copyCount: Int
}

/// What a history page asks the store for.
nonisolated struct PageRequest: Hashable, Sendable {
    var query = SearchQuery("")
    var filter = KindFilter.all
    /// The order of the last item of the previous page. Nil for the first page, which also holds
    /// the pinned items.
    var cursor: Int64?
    /// Unpinned items per page.
    var limit = 100
}

/// One page of the history: the pinned items on the first page, then unpinned items, newest first.
nonisolated struct HistoryPage: Sendable {
    var pinned: [ItemSummary]
    var items: [ItemSummary]
    /// Where the next page starts, when there is one.
    var nextCursor: Int64?
}

/// What a row carries for its actions: the item's key, kind and whether it is pinned. Small, so a
/// row stays well under the 1 KB a payload may take.
nonisolated struct RowPayload: Codable, Hashable, Sendable {
    var key: ItemKey
    var kind: ClipKind
    var isPinned: Bool
}

/// The periods Clear Recent Clipboard History offers. The raw value is the argument's value.
nonisolated enum RecentPeriod: String, CaseIterable, Sendable {
    case fiveMinutes = "5m"
    case fifteenMinutes = "15m"
    case hour = "1h"
    case day = "24h"

    var seconds: TimeInterval {
        switch self {
        case .fiveMinutes: 5 * 60
        case .fifteenMinutes: 15 * 60
        case .hour: 60 * 60
        case .day: 24 * 60 * 60
        }
    }
}
