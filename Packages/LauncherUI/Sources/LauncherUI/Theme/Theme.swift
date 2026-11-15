/// Every colour, font, metric and animation constant the launcher draws with, in one value.
///
/// Views read numbers from here and nowhere else, so a user can restyle the launcher with a theme
/// file without touching code. Encode `Theme.standard` to get a complete file to start from.
nonisolated public struct Theme: Codable, Sendable, Equatable {
    public var panel: PanelMetrics
    public var queryRow: QueryRowMetrics
    public var list: ListMetrics
    public var lens: LensMetrics
    public var actionBar: ActionBarMetrics
    public var grid: GridMetrics
    public var detail: DetailMetrics
    public var card: CardMetrics
    public var form: FormMetrics
    public var chips: ChipMetrics
    public var feedback: FeedbackMetrics
    public var motion: MotionMetrics
    public var fonts: ThemeFonts
    public var light: ThemePalette
    public var dark: ThemePalette
    /// Scales the alpha of the appearance tint on the glass. 1 is the tuned default: the least
    /// tint that meets the contrast targets over every test backdrop. Higher values trade glass
    /// for legibility; 0 shows the untinted glass.
    public var clarity: Double

    public init(
        panel: PanelMetrics, queryRow: QueryRowMetrics, list: ListMetrics, lens: LensMetrics,
        actionBar: ActionBarMetrics, grid: GridMetrics, detail: DetailMetrics, card: CardMetrics, form: FormMetrics,
        chips: ChipMetrics, feedback: FeedbackMetrics, motion: MotionMetrics, fonts: ThemeFonts,
        light: ThemePalette, dark: ThemePalette, clarity: Double
    ) {
        self.panel = panel
        self.queryRow = queryRow
        self.list = list
        self.lens = lens
        self.actionBar = actionBar
        self.grid = grid
        self.detail = detail
        self.card = card
        self.form = form
        self.chips = chips
        self.feedback = feedback
        self.motion = motion
        self.fonts = fonts
        self.light = light
        self.dark = dark
        self.clarity = clarity
    }

    /// The palette for an appearance.
    public func palette(dark isDark: Bool) -> ThemePalette { isDark ? dark : light }

    /// Height of the glass for a given content height. Zero content shows the query row alone,
    /// with no hairline and no action bar (the compact look).
    public func glassHeight(contentHeight: Double) -> Double {
        guard contentHeight > 0 else { return queryRow.height }
        return queryRow.height + min(contentHeight, panel.maxContentHeight) + actionBar.height
    }

    /// The tallest the glass can be. The window is sized for this once.
    public var maxGlassHeight: Double { glassHeight(contentHeight: panel.maxContentHeight) }
}
