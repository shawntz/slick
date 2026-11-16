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

    /// Height of the glass for a given content height: from the top of the query row to the
    /// bottom of the action bar, and in the split layout the gap between the pieces too. Zero
    /// content shows the query row alone, with no hairline, no action bar and no results
    /// container (the compact look). `showsToast` says whether a toast shows, for a theme whose
    /// action bar shows only then.
    public func glassHeight(contentHeight: Double, showsToast: Bool = false) -> Double {
        guard contentHeight > 0 else { return queryRow.height }
        return queryRow.height + resultsOffset + min(contentHeight, panel.maxContentHeight)
            + actionBarHeight(showsToast: showsToast)
    }

    /// The room the action bar takes under the content: its height, or nothing while a theme that
    /// shows the bar only for toasts has none to show.
    public func actionBarHeight(showsToast: Bool) -> Double {
        actionBar.showsOnlyForToasts && !showsToast ? 0 : actionBar.height
    }

    /// The gap above the content: zero in one piece, `fieldGap` between the split pieces.
    var resultsOffset: Double { panel.layout == .split ? panel.fieldGap : 0 }

    /// The query row glass's corner radius in the split layout: never more than half its height.
    public var fieldCornerRadius: Double { min(panel.fieldCornerRadius, queryRow.height / 2) }

    /// The tallest the glass can be, a toast included. The window is sized for this once.
    public var maxGlassHeight: Double { glassHeight(contentHeight: panel.maxContentHeight, showsToast: true) }
}
