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

/// The style of the panel's glass.
nonisolated public enum GlassStyle: String, Codable, Sendable, CaseIterable {
    /// The system's standard glass: it blurs and frosts what is behind it.
    case regular
    /// The system's clear glass: the most translucent the glass can be. Text over it depends on
    /// the theme's weight, colour and halo, because the glass hardly evens out the backdrop.
    case clear
}

/// How the panel's glass is arranged.
nonisolated public enum PanelLayout: String, Codable, Sendable, CaseIterable {
    /// One piece of glass: the query row, then the content and the action bar.
    case single
    /// Two pieces of the same width: the query row in its own glass, and below it, `fieldGap`
    /// apart, a results container with the content and the action bar. The container hides while
    /// there is no content.
    case split
}

/// The window and the glass inside it.
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
    /// The glass style of the panel body. Cards, menus, the lens and the HUD stay regular glass.
    public var glassStyle: GlassStyle = .regular
    /// One piece of glass, or the query row apart from a results container.
    public var layout: PanelLayout = .single
    /// In the split layout, the space between the query row's glass and the results container.
    public var fieldGap: Double = 10
    /// In the split layout, the corner radius of the query row's glass. It is never more than half
    /// the row's height, so a large value makes a capsule. `cornerRadius` shapes the results.
    public var fieldCornerRadius: Double = 30
    /// Width of a bright line along the lower half of each piece's edge, in the palette's `rim`
    /// colour. Zero draws none.
    public var rimWidth: Double = 0
    /// Blur radius of a shadow under the glass in the palette's `shadow` colour, beyond the shadow
    /// the glass draws itself. Zero draws none. Leave room for it in `shadowInsets`.
    public var shadowRadius: Double = 0
    /// How far that shadow falls below the glass.
    public var shadowOffset: Double = 0
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
    /// Whether the magnifier shows at root. Without it the text starts at `leadingInset`. Inside a
    /// view the back chevron always shows.
    public var showsRootGlyph: Bool = true
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
    /// Whether the first nine rows show the Command-digit chord that runs them, at the trailing
    /// edge in the run hint font and colour. Rows are counted across sections, as the keys count
    /// them, and scrolling does not renumber them.
    public var showsRunHints: Bool = false
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
    /// Whether the bar shows only while a toast shows. The glass then leaves no room for it the
    /// rest of the time, and grows by the bar's height for a toast. Command-K still opens the
    /// action panel.
    public var showsOnlyForToasts: Bool = false
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
    /// The Command-digit hint at the end of a row, when the list shows them.
    public var runHint: ThemeFont = ThemeFont(size: 12.5)
}

extension PanelMetrics {
    /// Reads a theme file. A file made before the glass style, the layout, the rim and the shadow
    /// were added loads as one piece of regular glass with neither rim nor extra shadow.
    nonisolated public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        width = try values.value(.width)
        cornerRadius = try values.value(.cornerRadius)
        topFraction = try values.value(.topFraction)
        shadowInsets = try values.value(.shadowInsets)
        maxContentHeight = try values.value(.maxContentHeight)
        minimumScreenMargin = try values.value(.minimumScreenMargin)
        hairlinePixels = try values.value(.hairlinePixels)
        glassStyle = try values.value(.glassStyle, or: .regular)
        layout = try values.value(.layout, or: .single)
        fieldGap = try values.value(.fieldGap, or: 10)
        fieldCornerRadius = try values.value(.fieldCornerRadius, or: 30)
        rimWidth = try values.value(.rimWidth, or: 0)
        shadowRadius = try values.value(.shadowRadius, or: 0)
        shadowOffset = try values.value(.shadowOffset, or: 0)
    }
}

extension QueryRowMetrics {
    /// Reads a theme file. A file made before `showsRootGlyph` was added shows the magnifier.
    nonisolated public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        height = try values.value(.height)
        leadingInset = try values.value(.leadingInset)
        glyphSlotWidth = try values.value(.glyphSlotWidth)
        glyphSize = try values.value(.glyphSize)
        textGap = try values.value(.textGap)
        trailingInset = try values.value(.trailingInset)
        breadcrumbHeight = try values.value(.breadcrumbHeight)
        breadcrumbPadding = try values.value(.breadcrumbPadding)
        breadcrumbMaxFraction = try values.value(.breadcrumbMaxFraction)
        showsRootGlyph = try values.value(.showsRootGlyph, or: true)
    }
}

extension ListMetrics {
    /// Reads a theme file. A file made before `showsRunHints` was added shows no run hints.
    nonisolated public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rowHeight = try values.value(.rowHeight)
        twoLineRowHeight = try values.value(.twoLineRowHeight)
        twoLineGap = try values.value(.twoLineGap)
        iconSize = try values.value(.iconSize)
        iconX = try values.value(.iconX)
        iconPlaceholderRadius = try values.value(.iconPlaceholderRadius)
        iconTextGap = try values.value(.iconTextGap)
        titleSubtitleGap = try values.value(.titleSubtitleGap)
        minimumSubtitleWidth = try values.value(.minimumSubtitleWidth)
        trailingInset = try values.value(.trailingInset)
        accessorySpacing = try values.value(.accessorySpacing)
        maxAccessoryFraction = try values.value(.maxAccessoryFraction)
        accessoryGap = try values.value(.accessoryGap)
        accessoryIconSize = try values.value(.accessoryIconSize)
        sectionHeaderHeight = try values.value(.sectionHeaderHeight)
        sectionHeaderX = try values.value(.sectionHeaderX)
        sectionHeaderBaseline = try values.value(.sectionHeaderBaseline)
        verticalPadding = try values.value(.verticalPadding)
        maxVisibleRows = try values.value(.maxVisibleRows)
        tagHeight = try values.value(.tagHeight)
        tagPadding = try values.value(.tagPadding)
        keycapHeight = try values.value(.keycapHeight)
        keycapMinWidth = try values.value(.keycapMinWidth)
        keycapPadding = try values.value(.keycapPadding)
        keycapRadius = try values.value(.keycapRadius)
        keycapSpacing = try values.value(.keycapSpacing)
        scrollIndicatorWidth = try values.value(.scrollIndicatorWidth)
        scrollIndicatorInset = try values.value(.scrollIndicatorInset)
        scrollIndicatorLinger = try values.value(.scrollIndicatorLinger)
        wheelLineHeight = try values.value(.wheelLineHeight)
        showsRunHints = try values.value(.showsRunHints, or: false)
    }
}

extension ActionBarMetrics {
    /// Reads a theme file. A file made before `showsOnlyForToasts` was added always shows the bar.
    nonisolated public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        height = try values.value(.height)
        horizontalInset = try values.value(.horizontalInset)
        iconSize = try values.value(.iconSize)
        itemSpacing = try values.value(.itemSpacing)
        dividerSpacing = try values.value(.dividerSpacing)
        dividerHeight = try values.value(.dividerHeight)
        keycapHeight = try values.value(.keycapHeight)
        keycapMinWidth = try values.value(.keycapMinWidth)
        keycapPadding = try values.value(.keycapPadding)
        keycapRadius = try values.value(.keycapRadius)
        keycapSpacing = try values.value(.keycapSpacing)
        titleMaxFraction = try values.value(.titleMaxFraction)
        showsOnlyForToasts = try values.value(.showsOnlyForToasts, or: false)
    }
}

extension ThemeFonts {
    /// Reads a theme file. A file made before `runHint` was added takes its own accessory font.
    nonisolated public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        query = try values.value(.query)
        title = try values.value(.title)
        subtitle = try values.value(.subtitle)
        accessory = try values.value(.accessory)
        sectionHeader = try values.value(.sectionHeader)
        tag = try values.value(.tag)
        keycap = try values.value(.keycap)
        breadcrumb = try values.value(.breadcrumb)
        actionBar = try values.value(.actionBar)
        actionBarPrimary = try values.value(.actionBarPrimary)
        actionBarKeycap = try values.value(.actionBarKeycap)
        gridTitle = try values.value(.gridTitle)
        gridSubtitle = try values.value(.gridSubtitle)
        detailText = try values.value(.detailText)
        detailMonospaced = try values.value(.detailMonospaced)
        markdownHeadings = try values.value(.markdownHeadings)
        metadataLabel = try values.value(.metadataLabel)
        metadataValue = try values.value(.metadataValue)
        cardFilter = try values.value(.cardFilter)
        cardRow = try values.value(.cardRow)
        cardSection = try values.value(.cardSection)
        confirmTitle = try values.value(.confirmTitle)
        confirmMessage = try values.value(.confirmMessage)
        button = try values.value(.button)
        formLabel = try values.value(.formLabel)
        formControl = try values.value(.formControl)
        formMessage = try values.value(.formMessage)
        chip = try values.value(.chip)
        emptyTitle = try values.value(.emptyTitle)
        emptyHint = try values.value(.emptyHint)
        hud = try values.value(.hud)
        runHint = try values.value(.runHint, or: accessory)
    }
}
