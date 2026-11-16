/// The colours for one appearance. A theme carries one palette for light and one for dark.
///
/// Result rows are drawn with Core Text, which gets no vibrancy from the glass, so these colours
/// alone decide how readable a row is. The glass rules in docs/ARCHITECTURE.md set the contrast
/// targets; `make ui-shots` measures them over three backdrops.
nonisolated public struct ThemePalette: Codable, Sendable, Equatable {
    /// Tint laid over the glass toward the appearance's base colour. `Theme.clarity` scales its
    /// alpha. It is dropped under Reduce Transparency, where the system glass is already opaque.
    public var glassTint: ThemeColor
    /// Title text, and matched characters while a query is active.
    public var title: ThemeColor
    /// Alpha multiplier for title characters that did not match while a query is active.
    public var unmatchedTitleAlpha: Double
    public var subtitle: ThemeColor
    /// Plain-text accessories at the trailing edge of a row.
    public var accessory: ThemeColor
    public var sectionHeader: ThemeColor
    /// The ghost completion after the typed query.
    public var ghostText: ThemeColor
    /// The hairline under the query row.
    public var hairline: ThemeColor
    /// The fill-style selection lens.
    public var lensFill: ThemeColor
    /// The tint of the glass-style selection lens.
    public var lensGlassTint: ThemeColor
    /// The rounded square drawn until a row's icon arrives.
    public var iconPlaceholder: ThemeColor
    public var keycapFill: ThemeColor
    public var keycapText: ThemeColor
    /// Alpha of a tag capsule's fill, applied to the tag's own colour.
    public var tagFillAlpha: Double
    /// How far a tag's text moves from its colour toward the title colour, from 0 to 1.
    public var tagTextDepth: Double
    public var scrollIndicator: ThemeColor
    /// An optional soft glow in the opposite luminance behind row text. Nil draws none.
    public var textHalo: ThemeColor?
    /// Blur radius of the halo, in points.
    public var textHaloRadius: Double
    /// The tile behind each grid cell's content.
    public var tileFill: ThemeColor
    /// Body text in the detail pane.
    public var detailText: ThemeColor
    /// The underline under links in Markdown and metadata. Link text itself uses the body colour,
    /// because no accent colour reaches 4.5:1 on every glass and backdrop.
    public var link: ThemeColor
    /// The background of Markdown code spans and code blocks.
    public var codeFill: ThemeColor
    /// Tint of the nested glass under cards and menus. Stronger than the panel's, so a card reads
    /// as a layer above the content.
    public var cardTint: ThemeColor
    /// The selected row in a card or menu.
    public var cardSelection: ThemeColor
    /// The inset background of form fields and argument chips.
    public var fieldFill: ThemeColor
    /// The ring around the focused field.
    public var focusRing: ThemeColor
    /// Error text under a form field. Deeper than the system red in light mode and lighter in dark
    /// mode, so it reaches 3:1 on mid-grey glass.
    public var error: ThemeColor
    /// A destructive action's title and a destructive confirm button.
    public var destructive: ThemeColor
    /// The default button in a confirm card and a checked checkbox.
    public var prominent: ThemeColor
    /// Text on a prominent or destructive fill.
    public var onProminent: ThemeColor
    /// A keycap on a prominent or destructive fill.
    public var onProminentKeycap: ThemeColor
    /// The moving segment of the loading bar.
    public var loadingBar: ThemeColor
    /// Tint of the HUD's glass. The HUD is never key, so its glass is flatter than the panel's.
    public var hudTint: ThemeColor
    /// In the split layout, the tint of the query row's glass. The results container takes
    /// `glassTint`. Scaled and dropped as `glassTint` is.
    public var fieldTint = ThemeColor(.white, alpha: 0)
    /// In the split layout, a shade over the query row's glass in this colour at its top edge,
    /// fading to nothing at its bottom edge. Dropped under Reduce Transparency.
    public var fieldShade = ThemeColor(.black, alpha: 0)
    /// The bright line along the lower half of the glass's edge, `PanelMetrics.rimWidth` wide.
    public var rim = ThemeColor(.white, alpha: 0)
    /// The shadow under the glass, `PanelMetrics.shadowRadius` wide. Its alpha is the opacity.
    public var shadow = ThemeColor(.black, alpha: 0)
    /// The text caret of the query field and every other field in the panel.
    public var caret = ThemeColor(.accent)
    /// A soft glow around the query field's caret, its colours from top to bottom. Empty draws
    /// none. Each colour's alpha sets the glow's strength there.
    public var caretGlow: [ThemeColor] = []
    /// The Command-digit hint at the end of a row, when the list shows them.
    public var runHint = ThemeColor(.label, alpha: 0.72)
    /// How many times the halo is laid down behind the text. Each layer makes it denser, for glass
    /// that does not even out the backdrop. The text is drawn once per layer, so it also gets a
    /// little heavier.
    public var textHaloLayers = 1
    /// The query field's placeholder. A system colour keeps the field's vibrancy.
    public var placeholder = ThemeColor(.tertiaryLabel)
    /// The large symbol of an empty state. A system colour keeps its vibrancy.
    public var emptySymbol = ThemeColor(.tertiaryLabel)
}

extension ThemePalette {
    /// Reads a theme file. A file made before the colours of the split layout, the caret, the run
    /// hint, the placeholder and the empty symbol were added loads with none of the new decoration
    /// and a halo of one layer: its caret takes `prominent`, its run hint `accessory`, its query
    /// row's glass `glassTint`, and its placeholder and empty symbol the system's tertiary label,
    /// as before.
    nonisolated public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        glassTint = try values.value(.glassTint)
        title = try values.value(.title)
        unmatchedTitleAlpha = try values.value(.unmatchedTitleAlpha)
        subtitle = try values.value(.subtitle)
        accessory = try values.value(.accessory)
        sectionHeader = try values.value(.sectionHeader)
        ghostText = try values.value(.ghostText)
        hairline = try values.value(.hairline)
        lensFill = try values.value(.lensFill)
        lensGlassTint = try values.value(.lensGlassTint)
        iconPlaceholder = try values.value(.iconPlaceholder)
        keycapFill = try values.value(.keycapFill)
        keycapText = try values.value(.keycapText)
        tagFillAlpha = try values.value(.tagFillAlpha)
        tagTextDepth = try values.value(.tagTextDepth)
        scrollIndicator = try values.value(.scrollIndicator)
        textHalo = try values.decodeIfPresent(ThemeColor.self, forKey: .textHalo)
        textHaloRadius = try values.value(.textHaloRadius)
        tileFill = try values.value(.tileFill)
        detailText = try values.value(.detailText)
        link = try values.value(.link)
        codeFill = try values.value(.codeFill)
        cardTint = try values.value(.cardTint)
        cardSelection = try values.value(.cardSelection)
        fieldFill = try values.value(.fieldFill)
        focusRing = try values.value(.focusRing)
        error = try values.value(.error)
        destructive = try values.value(.destructive)
        prominent = try values.value(.prominent)
        onProminent = try values.value(.onProminent)
        onProminentKeycap = try values.value(.onProminentKeycap)
        loadingBar = try values.value(.loadingBar)
        hudTint = try values.value(.hudTint)
        fieldTint = try values.value(.fieldTint, or: glassTint)
        fieldShade = try values.value(.fieldShade, or: ThemeColor(.black, alpha: 0))
        rim = try values.value(.rim, or: ThemeColor(.white, alpha: 0))
        shadow = try values.value(.shadow, or: ThemeColor(.black, alpha: 0))
        caret = try values.value(.caret, or: prominent)
        caretGlow = try values.value(.caretGlow, or: [])
        runHint = try values.value(.runHint, or: accessory)
        textHaloLayers = try values.value(.textHaloLayers, or: 1)
        placeholder = try values.value(.placeholder, or: ThemeColor(.tertiaryLabel))
        emptySymbol = try values.value(.emptySymbol, or: ThemeColor(.tertiaryLabel))
    }
}
