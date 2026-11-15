import CoreGraphics

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

    public init(
        id: UInt64, title: String, titleHighlights: [HighlightRange] = [], subtitle: String = "",
        accessories: [RowAccessory] = [], icon: CGImage? = nil, accessibilityLabel: String? = nil
    ) {
        self.id = id
        self.title = title
        self.titleHighlights = titleHighlights
        self.subtitle = subtitle
        self.accessories = accessories
        self.icon = icon
        self.accessibilityLabel = accessibilityLabel
    }

    public static func == (lhs: ListRow, rhs: ListRow) -> Bool {
        lhs.id == rhs.id && lhs.icon === rhs.icon && lhs.title == rhs.title && lhs.subtitle == rhs.subtitle
            && lhs.titleHighlights == rhs.titleHighlights && lhs.accessories == rhs.accessories
            && lhs.accessibilityLabel == rhs.accessibilityLabel
    }
}

/// Rows under an optional header.
nonisolated public struct ListSection: Sendable, Equatable {
    /// The header text, or nil for a section without a header.
    public var title: String?
    public var rows: [ListRow]

    public init(title: String? = nil, rows: [ListRow]) {
        self.title = title
        self.rows = rows
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
