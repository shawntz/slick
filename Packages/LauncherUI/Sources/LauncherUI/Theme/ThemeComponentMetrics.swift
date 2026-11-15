// Metrics for the grid, the detail pane, the cards, forms, the query row's chips, and feedback
// surfaces (empty state, loading bar, HUD). One part per area, like `ListMetrics`.

/// Cells in columns, under optional section headers. Headers reuse `ListMetrics`.
nonisolated public struct GridMetrics: Codable, Sendable, Equatable {
    /// Columns for glyph-sized items such as emoji or symbols.
    public var glyphColumns: Int
    /// Columns for image items such as screenshots or thumbnails.
    public var imageColumns: Int
    /// Distance from the glass edge to the first and last column.
    public var horizontalInset: Double
    /// Space between cells, across and down.
    public var spacing: Double
    /// Corner radius of the tile behind each cell's content.
    public var tileCornerRadius: Double
    /// Space between a tile's edge and an image inside it.
    public var imagePadding: Double
    /// Glyph size as a share of the tile's height.
    public var glyphScale: Double
    /// Space between a tile and its title.
    public var titleGap: Double
    /// Height of the title line under a tile.
    public var titleHeight: Double
    /// Height of the subtitle line under a title, when cells have subtitles.
    public var subtitleHeight: Double
    /// Space above the first and below the last row of cells.
    public var verticalPadding: Double
    /// Corner radius of the selection lens around a cell's tile.
    public var lensCornerRadius: Double
    /// How far the lens reaches outside the selected cell's tile.
    public var lensOutset: Double
}

/// The detail pane beside a list, and its metadata table.
nonisolated public struct DetailMetrics: Codable, Sendable, Equatable {
    /// The list's share of the content width when a detail pane shows. The pane takes the rest.
    public var listFraction: Double
    /// Space between the pane's edges and its text.
    public var padding: Double
    /// Space between an image or thumbnail and the pane's edges.
    public var imagePadding: Double
    /// Extra space between lines of body text.
    public var lineSpacing: Double
    /// Space after each paragraph of body text.
    public var paragraphSpacing: Double
    /// Space inside a Markdown code block, around its text.
    public var codeBlockPadding: Double
    /// Indent of list items and block quotes in Markdown.
    public var listIndent: Double
    /// Height of a colour swatch.
    public var swatchHeight: Double
    /// Corner radius of a colour swatch and a file thumbnail.
    public var swatchCornerRadius: Double
    /// Edge length of a file thumbnail.
    public var thumbnailSize: Double
    /// Height of one metadata row.
    public var metadataRowHeight: Double
    /// Space above and below the hairline between metadata groups.
    public var metadataGroupGap: Double
    /// The tallest the metadata table may grow, as a share of the pane's height. Past it, it scrolls.
    public var metadataMaxFraction: Double
}

/// The action card, the confirm card and the dropdown menu: small nested glass cards inside the panel.
nonisolated public struct CardMetrics: Codable, Sendable, Equatable {
    /// Width of the action card.
    public var width: Double
    /// Width of the confirm card.
    public var confirmWidth: Double
    /// Width of a dropdown menu, unless its anchor is wider.
    public var menuWidth: Double
    /// Space between a card and the edges it is anchored to.
    public var margin: Double
    public var cornerRadius: Double
    /// Corner radius of a dropdown menu.
    public var menuCornerRadius: Double
    /// Height of the action card's filter field.
    public var filterHeight: Double
    /// Distance from the card edge to the filter text and to row content.
    public var horizontalPadding: Double
    /// Space above the first row and below the last.
    public var verticalPadding: Double
    public var rowHeight: Double
    /// Height of a dropdown menu row.
    public var menuRowHeight: Double
    public var iconSize: Double
    /// Space between a row's icon and its title.
    public var iconGap: Double
    public var sectionHeaderHeight: Double
    /// Baseline of the section header text, from the top of the header.
    public var sectionHeaderBaseline: Double
    /// Distance from a row's edge to the selection fill, on both sides.
    public var selectionInset: Double
    public var selectionCornerRadius: Double
    /// Rows visible before the card scrolls.
    public var maxVisibleRows: Int
    /// Opacity of everything behind an open card that dims.
    public var dimAlpha: Double
    /// Space inside the confirm card.
    public var confirmPadding: Double
    /// Space between the confirm card's title and message, and between the message and the buttons.
    public var confirmGap: Double
    public var buttonHeight: Double
    public var buttonCornerRadius: Double
    /// Space inside a button between its edge and its title, and between the title and its keycap.
    public var buttonPadding: Double
    public var buttonSpacing: Double
}

/// Forms inside the panel.
nonisolated public struct FormMetrics: Codable, Sendable, Equatable {
    /// Width of the right-aligned label column.
    public var labelWidth: Double
    /// Space between the label column and the controls.
    public var labelGap: Double
    /// Distance from the glass edge to the label column and from the controls to the other edge.
    public var horizontalInset: Double
    /// Space above the first field and below the last.
    public var verticalPadding: Double
    /// Space between fields.
    public var rowSpacing: Double
    public var controlHeight: Double
    /// Height of a multiline text field.
    public var multilineHeight: Double
    public var fieldCornerRadius: Double
    /// Space between a field's edge and its text.
    public var fieldPadding: Double
    /// Width of the focus ring around the focused field.
    public var focusRingWidth: Double
    /// Space between a field and the error or info text under it.
    public var messageGap: Double
    /// Height of one line of error or info text.
    public var messageHeight: Double
    public var checkboxSize: Double
    public var checkboxCornerRadius: Double
    /// Height of a tag capsule in a tag field.
    public var tagHeight: Double
    public var tagSpacing: Double
    /// Height of the hairline in a separator row, and of the space around it.
    public var separatorHeight: Double
}

/// Inline argument chips and the filter dropdown chip in the query row.
nonisolated public struct ChipMetrics: Codable, Sendable, Equatable {
    /// At most this many argument chips show after the query text.
    public var maxArguments: Int
    public var height: Double
    public var cornerRadius: Double
    /// Space between a chip's edge and its text.
    public var padding: Double
    /// Space between chips, and between the query text and the first chip.
    public var spacing: Double
    public var minimumWidth: Double
    public var maximumWidth: Double
    /// Size of the chevron in dropdown chips.
    public var chevronSize: Double
}

/// The empty state, the loading bar and the HUD.
nonisolated public struct FeedbackMetrics: Codable, Sendable, Equatable {
    /// Height the empty state asks of the content area.
    public var emptyStateHeight: Double
    public var emptySymbolSize: Double
    /// Space between the symbol and the title.
    public var emptyTitleGap: Double
    /// Space between the title and the hint.
    public var emptyHintGap: Double
    /// Width of the hint before it wraps.
    public var emptyHintWidth: Double
    public var loadingBarHeight: Double
    /// Length of the moving segment as a share of the panel width.
    public var loadingSegmentFraction: Double
    public var hudHeight: Double
    /// Space between the HUD's edge and its content.
    public var hudPadding: Double
    public var hudSymbolSize: Double
    /// Space between the HUD's symbol and its text.
    public var hudSymbolGap: Double
    /// Distance from the bottom of the screen's visible frame to the HUD.
    public var hudBottomMargin: Double
    /// Seconds the HUD stays fully shown.
    public var hudDuration: Double
    /// Transparent space around the HUD capsule for the glass shadow.
    public var hudShadowInset: Double
}
