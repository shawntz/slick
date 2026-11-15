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
}
