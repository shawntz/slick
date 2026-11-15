import CoreGraphics

/// Edge insets that a theme can encode.
nonisolated public struct ThemeInsets: Codable, Sendable, Equatable, Hashable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public init(top: Double, left: Double, bottom: Double, right: Double) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}

/// The window and the glass slab inside it.
nonisolated public struct PanelMetrics: Codable, Sendable, Equatable {
    /// Width of the glass.
    public var width: Double
    /// Corner radius of the glass.
    public var cornerRadius: Double
    /// How far down the screen's visible frame the top of the glass sits, from 0 (top) to 1.
    public var topFraction: Double
    /// Transparent space around the glass inside the window. The glass draws its own shadow
    /// outside its shape, so the window must leave room for it or the shadow is clipped.
    public var shadowInsets: ThemeInsets
    /// The tallest the content area between the query row and the action bar may grow. The window
    /// is sized for it once, so the panel never resizes its window.
    public var maxContentHeight: Double
    /// Smallest gap kept between the glass and the bottom of the visible frame on short screens.
    public var minimumScreenMargin: Double
    /// Height of the hairline under the query row, in pixels.
    public var hairlinePixels: Double
}

/// The query row at the top of the glass.
nonisolated public struct QueryRowMetrics: Codable, Sendable, Equatable {
    public var height: Double
    /// Space between the glass edge and the leading glyph slot.
    public var leadingInset: Double
    /// Width of the leading glyph slot (magnifier or back chevron).
    public var glyphSlotWidth: Double
    /// Point size of the leading glyph.
    public var glyphSize: Double
    /// Space between the leading slot and the text.
    public var textGap: Double
    /// Space between the text and the trailing slot, and between the trailing slot and the edge.
    public var trailingInset: Double
    /// Height of the breadcrumb capsule shown in the leading slot inside a view.
    public var breadcrumbHeight: Double
    /// Horizontal padding inside the breadcrumb capsule.
    public var breadcrumbPadding: Double
    /// Largest share of the row width the breadcrumb may take.
    public var breadcrumbMaxFraction: Double
}

/// Result rows, section headers and their accessories.
nonisolated public struct ListMetrics: Codable, Sendable, Equatable {
    /// Height of a one-line row.
    public var rowHeight: Double
    /// Height of a two-line row (title above subtitle).
    public var twoLineRowHeight: Double
    /// Gap between the title and subtitle lines of a two-line row.
    public var twoLineGap: Double
    public var iconSize: Double
    /// Distance from the glass edge to the icon.
    public var iconX: Double
    /// Corner radius of the placeholder drawn until an icon arrives.
    public var iconPlaceholderRadius: Double
    /// Space between the icon and the title.
    public var iconTextGap: Double
    /// Space between the title and the subtitle on a one-line row.
    public var titleSubtitleGap: Double
    /// Narrowest subtitle worth drawing. Narrower ones are dropped so the title keeps its room.
    public var minimumSubtitleWidth: Double
    /// Space between the last accessory and the glass edge.
    public var trailingInset: Double
    /// Space between accessories.
    public var accessorySpacing: Double
    /// Largest share of the row width the accessories may take before they are truncated.
    public var maxAccessoryFraction: Double
    /// Space between the text and the first accessory.
    public var accessoryGap: Double
    public var accessoryIconSize: Double
    public var sectionHeaderHeight: Double
    /// Distance from the glass edge to the section header text.
    public var sectionHeaderX: Double
    /// Baseline of the section header text, from the top of the header.
    public var sectionHeaderBaseline: Double
    /// Space above the first line and below the last line of the list.
    public var verticalPadding: Double
    /// Rows visible before the list scrolls.
    public var maxVisibleRows: Int
    public var tagHeight: Double
    public var tagPadding: Double
    public var keycapHeight: Double
    public var keycapMinWidth: Double
    public var keycapPadding: Double
    public var keycapRadius: Double
    /// Space between the keycaps of one shortcut.
    public var keycapSpacing: Double
    /// Width of the scroll indicator shown while the list scrolls.
    public var scrollIndicatorWidth: Double
    /// Distance from the scroll indicator to the glass edge.
    public var scrollIndicatorInset: Double
    /// Seconds the scroll indicator stays after the last scroll event.
    public var scrollIndicatorLinger: Double
    /// Points scrolled per line for a mouse wheel that reports whole lines.
    public var wheelLineHeight: Double
}

/// The selection lens behind the selected row.
nonisolated public struct LensMetrics: Codable, Sendable, Equatable {
    /// How the lens is drawn.
    public enum Style: String, Codable, Sendable, CaseIterable {
        /// A nested glass view tinted with the accent colour.
        case glass
        /// A flat fill in the label colour at low alpha.
        case fill
    }

    public var style: Style
    /// Distance from the glass edge to the lens on the left and right.
    public var horizontalInset: Double
    public var cornerRadius: Double
}

/// The action bar at the bottom of the glass.
nonisolated public struct ActionBarMetrics: Codable, Sendable, Equatable {
    public var height: Double
    /// Distance from the glass edge to the content on both sides.
    public var horizontalInset: Double
    /// Size of the view icon and the toast symbol in the left region.
    public var iconSize: Double
    /// Space between an icon and its text, and between a title and its keycap.
    public var itemSpacing: Double
    /// Space on each side of the divider between the primary action and "Actions".
    public var dividerSpacing: Double
    /// Height of the divider between the primary action and "Actions".
    public var dividerHeight: Double
    public var keycapHeight: Double
    public var keycapMinWidth: Double
    public var keycapPadding: Double
    public var keycapRadius: Double
    public var keycapSpacing: Double
    /// Largest share of the bar width the primary action title or the actions title may take.
    public var titleMaxFraction: Double
}

/// Durations and frame counts. Under Reduce Motion every one of them is treated as zero.
nonisolated public struct MotionMetrics: Codable, Sendable, Equatable {
    /// Perceptual duration of the lens position spring, in seconds. It is critically damped.
    public var lensGlide: Double
    /// Duration of the glass height animation, in seconds.
    public var heightChange: Double
    /// Display refreshes over which the panel fades in at summon. Zero shows it in one step.
    public var summonRampFrames: Int
    /// Duration of the toast cross-fade in the action bar, in seconds.
    public var toastFade: Double
    /// Duration of the scroll indicator fade, in seconds.
    public var scrollIndicatorFade: Double
    /// Duration of a card or menu fading in or out, in seconds.
    public var cardFade: Double
    /// Duration of the content dimming behind an open card, in seconds.
    public var dimFade: Double
    /// Duration of the HUD fading in and out, in seconds.
    public var hudFade: Double
    /// Seconds for one sweep of the indeterminate loading bar.
    public var loadingSweep: Double
}

/// The type styles of the launcher.
nonisolated public struct ThemeFonts: Codable, Sendable, Equatable {
    public var query: ThemeFont
    public var title: ThemeFont
    public var subtitle: ThemeFont
    public var accessory: ThemeFont
    public var sectionHeader: ThemeFont
    public var tag: ThemeFont
    public var keycap: ThemeFont
    public var breadcrumb: ThemeFont
    public var actionBar: ThemeFont
    public var actionBarPrimary: ThemeFont
    public var actionBarKeycap: ThemeFont
    /// The title under a grid cell.
    public var gridTitle: ThemeFont
    public var gridSubtitle: ThemeFont
    /// Body text in the detail pane.
    public var detailText: ThemeFont
    /// Monospaced body text and Markdown code in the detail pane.
    public var detailMonospaced: ThemeFont
    /// Markdown headings, level 1 first. Deeper levels use the last entry.
    public var markdownHeadings: [ThemeFont]
    public var metadataLabel: ThemeFont
    public var metadataValue: ThemeFont
    /// The filter text in the action card.
    public var cardFilter: ThemeFont
    /// Row titles in the action card and dropdown menus.
    public var cardRow: ThemeFont
    public var cardSection: ThemeFont
    public var confirmTitle: ThemeFont
    public var confirmMessage: ThemeFont
    /// Button titles in cards.
    public var button: ThemeFont
    public var formLabel: ThemeFont
    /// Text inside form fields.
    public var formControl: ThemeFont
    /// Error and info text under form fields.
    public var formMessage: ThemeFont
    /// Text in the query row's argument and filter chips.
    public var chip: ThemeFont
    public var emptyTitle: ThemeFont
    public var emptyHint: ThemeFont
    public var hud: ThemeFont
}
