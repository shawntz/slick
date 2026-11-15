import CoreGraphics
import Foundation

/// A matched run of UTF-16 code units in a title, as the matcher reports it.
nonisolated public struct HighlightRange: Sendable, Equatable, Hashable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

/// Something at the trailing edge of a row.
nonisolated public enum RowAccessory: Sendable, Equatable {
    /// Plain text in the accessory colour.
    case text(String)
    /// Text in a capsule tinted with `color`.
    case tag(String, color: ThemeColor)
    /// A shortcut, one keycap per key: `["⌘", "1"]`.
    case keycaps([String])
    /// A small image, drawn at the theme's accessory icon size.
    case icon(CGImage)

    public static func == (lhs: RowAccessory, rhs: RowAccessory) -> Bool {
        switch (lhs, rhs) {
        case (.text(let a), .text(let b)): a == b
        case (.tag(let a, let colorA), .tag(let b, let colorB)): a == b && colorA == colorB
        case (.keycaps(let a), .keycaps(let b)): a == b
        case (.icon(let a), .icon(let b)): a === b
        default: false
        }
    }
}

/// One result row, with every string resolved and every highlight computed.
nonisolated public struct ListRow: Sendable, Equatable {
    /// Stable identity across updates, such as the engine key. `setIcon(_:forRow:)` finds rows by it.
    public var id: UInt64
    public var title: String
    /// Matched runs of the title, in UTF-16 offsets.
    public var titleHighlights: [HighlightRange]
    public var subtitle: String
    public var accessories: [RowAccessory]
    /// The icon, or nil to draw a placeholder until it arrives.
    public var icon: CGImage?
    /// What accessibility clients read. Nil reads "title, subtitle".
    public var accessibilityLabel: String?
    /// The subtitle's colour, or nil for the theme's subtitle colour. The list moves it toward the
    /// theme's title colour until it reaches 3:1 over the glass, as glass rule 5 asks of secondary
    /// text, so any colour stays readable in both appearances.
    public var subtitleColor: CGColor?

    public init(
        id: UInt64, title: String, titleHighlights: [HighlightRange] = [], subtitle: String = "",
        accessories: [RowAccessory] = [], icon: CGImage? = nil, accessibilityLabel: String? = nil,
        subtitleColor: CGColor? = nil
    ) {
        self.id = id
        self.title = title
        self.titleHighlights = titleHighlights
        self.subtitle = subtitle
        self.accessories = accessories
        self.icon = icon
        self.accessibilityLabel = accessibilityLabel
        self.subtitleColor = subtitleColor
    }

    public static func == (lhs: ListRow, rhs: ListRow) -> Bool {
        lhs.id == rhs.id && lhs.icon === rhs.icon && lhs.title == rhs.title && lhs.subtitle == rhs.subtitle
            && lhs.titleHighlights == rhs.titleHighlights && lhs.accessories == rhs.accessories
            && lhs.accessibilityLabel == rhs.accessibilityLabel && lhs.subtitleColor == rhs.subtitleColor
    }
}

/// Rows under an optional header.
nonisolated public struct ListSection: Sendable, Equatable {
    /// The header text, or nil for a section without a header.
    public var title: String?
    public var rows: [ListRow]
    /// A number drawn after the header text, such as how many rows the section holds. Nil draws
    /// none. A section with a count and no title shows a header with the count alone.
    public var count: Int?

    public init(title: String? = nil, rows: [ListRow], count: Int? = nil) {
        self.title = title
        self.rows = rows
        self.count = count
    }

    /// Whether the section draws a header line.
    var hasHeader: Bool { title != nil || count != nil }

    /// The header as drawn and read aloud, or nil for none.
    var headerText: String? { SectionHeader.text(title: title, count: count) }
}

/// The text of a list or grid section header: its title, then its count after an en space.
nonisolated enum SectionHeader {
    /// Half an em: a gap that scales with the header font and needs no theme metric.
    static let gap = "\u{2002}"

    static func text(title: String?, count: Int?) -> String? {
        switch (title, count) {
        case (nil, nil): nil
        case (let title?, nil): title
        case (nil, let count?): count.formatted()
        case (let title?, let count?): title + gap + count.formatted()
        }
    }

    /// What accessibility clients read: the title and the count as separate words.
    static func spoken(title: String?, count: Int?) -> String? {
        switch (title, count) {
        case (let title?, let count?): "\(title), \(count.formatted())"
        default: text(title: title, count: count)
        }
    }
}

/// How tall rows are and where the subtitle goes.
nonisolated public enum RowStyle: Sendable, Equatable {
    /// 44 pt rows with the subtitle after the title on the same baseline.
    case oneLine
    /// 52 pt rows with the subtitle under the title.
    case twoLine
}

/// Everything a result list shows.
nonisolated public struct ListContent: Sendable, Equatable {
    public var sections: [ListSection]
    public var rowStyle: RowStyle
    /// True while a query is active: unmatched title characters are drawn dimmer than matched
    /// ones. Rows without highlights keep their full colour.
    public var emphasizesMatches: Bool

    public init(sections: [ListSection], rowStyle: RowStyle = .oneLine, emphasizesMatches: Bool = false) {
        self.sections = sections
        self.rowStyle = rowStyle
        self.emphasizesMatches = emphasizesMatches
    }

    public static let empty = ListContent(sections: [])

    /// The number of rows across all sections.
    public var rowCount: Int { sections.reduce(0) { $0 + $1.rows.count } }
}
