import CoreGraphics

/// How many columns a grid has. The theme supplies the counts for the two common kinds, so a
/// restyled theme changes every grid of that kind.
nonisolated public enum GridColumns: Sendable, Equatable, Hashable {
    /// Glyph-sized items such as emoji or symbols: `GridMetrics.glyphColumns`.
    case glyph
    /// Image items such as screenshots: `GridMetrics.imageColumns`.
    case image
    /// An exact count, at least one.
    case fixed(Int)

    /// The column count for a theme.
    public func count(in metrics: GridMetrics) -> Int {
        switch self {
        case .glyph: max(1, metrics.glyphColumns)
        case .image: max(1, metrics.imageColumns)
        case .fixed(let count): max(1, count)
        }
    }
}

/// What fills a cell's tile.
nonisolated public enum GridCellContent: Sendable, Equatable {
    /// An image, aspect-fitted inside the tile. Nil shows the empty tile until it arrives.
    case image(CGImage?)
    /// Short text drawn large, usually one emoji or symbol character.
    case glyph(String)
    /// A colour swatch.
    case color(ThemeColor)

    public static func == (lhs: GridCellContent, rhs: GridCellContent) -> Bool {
        switch (lhs, rhs) {
        case (.image(let a), .image(let b)): a === b
        case (.glyph(let a), .glyph(let b)): a == b
        case (.color(let a), .color(let b)): a == b
        default: false
        }
    }
}

/// One grid cell, with every string resolved and every highlight computed.
nonisolated public struct GridCell: Sendable, Equatable {
    /// Stable identity across updates. `setImage(_:forCell:)` finds cells by it.
    public var id: UInt64
    public var content: GridCellContent
    /// Drawn under the tile when the grid shows titles.
    public var title: String
    /// Matched runs of the title, in UTF-16 offsets.
    public var titleHighlights: [HighlightRange]
    /// Drawn under the title when the grid shows titles. Empty draws none.
    public var subtitle: String
    /// What accessibility clients read. Nil reads the title.
    public var accessibilityLabel: String?

    public init(
        id: UInt64, content: GridCellContent, title: String = "", titleHighlights: [HighlightRange] = [],
        subtitle: String = "", accessibilityLabel: String? = nil
    ) {
        self.id = id
        self.content = content
        self.title = title
        self.titleHighlights = titleHighlights
        self.subtitle = subtitle
        self.accessibilityLabel = accessibilityLabel
    }
}

/// Cells under an optional header.
nonisolated public struct GridSection: Sendable, Equatable {
    public var title: String?
    public var cells: [GridCell]

    public init(title: String? = nil, cells: [GridCell]) {
        self.title = title
        self.cells = cells
    }
}

/// Everything a grid shows.
nonisolated public struct GridContent: Sendable, Equatable {
    public var sections: [GridSection]
    public var columns: GridColumns
    /// Tile width divided by tile height.
    public var aspectRatio: Double
    /// Draws each cell's title (and subtitle) under its tile.
    public var showsTitles: Bool
    /// True while a query is active: unmatched title characters are drawn dimmer.
    public var emphasizesMatches: Bool

    public init(
        sections: [GridSection], columns: GridColumns = .glyph, aspectRatio: Double = 1, showsTitles: Bool = true,
        emphasizesMatches: Bool = false
    ) {
        self.sections = sections
        self.columns = columns
        self.aspectRatio = aspectRatio
        self.showsTitles = showsTitles
        self.emphasizesMatches = emphasizesMatches
    }

    public static let empty = GridContent(sections: [])

    /// The number of cells across all sections.
    public var cellCount: Int { sections.reduce(0) { $0 + $1.cells.count } }

    /// Whether these settings lay cells out the same way, so only cell contents can differ.
    func hasSameShape(as other: GridContent) -> Bool {
        columns == other.columns && aspectRatio == other.aspectRatio && showsTitles == other.showsTitles
            && emphasizesMatches == other.emphasizesMatches
    }
}

/// A direction to move the grid selection.
nonisolated public enum GridDirection: Sendable, Equatable, CaseIterable {
    case left, right, up, down
}
