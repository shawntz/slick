extension Theme {
    /// Standard's one slab in the system's clear glass with no tint: the most translucent the
    /// glass can be. Clear glass hardly evens out what is behind it, so the text carries the
    /// legibility itself: semibold titles, stronger secondary text and a soft halo in the opposite
    /// tone. The lens, cards, menus and the HUD stay regular glass. Under Reduce Transparency the
    /// panel falls back to the system's opaque regular glass.
    public static let clear: Theme = {
        var theme = Theme.standard
        theme.panel.glassStyle = .clear
        theme.fonts.title = ThemeFont(size: 14.5, weight: .semibold)
        theme.fonts.sectionHeader = ThemeFont(size: 11.5, weight: .bold)
        theme.fonts.accessory = ThemeFont(size: 12.5, weight: .medium)
        theme.fonts.subtitle = ThemeFont(size: 13, weight: .medium)
        theme.fonts.runHint = theme.fonts.accessory
        theme.light = theme.light.clearGlass(halo: ThemeColor(.white, alpha: 0.95))
        theme.dark = theme.dark.clearGlass(halo: ThemeColor(.black, alpha: 0.95))
        return theme
    }()

    /// What the settings window says about Clear. The numbers are the worst case `make ui-shots`
    /// measures: a title against the least favourable backdrop right beside it.
    static let clearSummary =
        "Standard's slab in clear glass with no tint, the most translucent the glass can be. Nothing frosts "
        + "the backdrop, so text carries a soft halo instead. Where backdrop text or color sits right beside a "
        + "title, it can fall to 1 to 1, far below the 4.5 to 1 of the other themes: over every test backdrop "
        + "but a dark one in dark mode the worst cases run from 1.0 to 3.7 to 1. The typed query fades the same "
        + "way over a page of text."
}

extension ThemePalette {
    /// The palette over clear glass: no tint, secondary text near full strength and a halo.
    fileprivate func clearGlass(halo: ThemeColor) -> ThemePalette {
        var palette = self
        palette.glassTint = ThemeColor(glassTint.source == .system(.black) ? .black : .white, alpha: 0)
        palette.fieldTint = palette.glassTint
        palette.subtitle = ThemeColor(.label, alpha: 0.85)
        palette.accessory = ThemeColor(.label, alpha: 0.85)
        palette.sectionHeader = ThemeColor(.label, alpha: 0.85)
        palette.runHint = ThemeColor(.label, alpha: 0.85)
        palette.ghostText = ThemeColor(.label, alpha: 0.6)
        palette.textHalo = halo
        palette.textHaloRadius = 3
        palette.textHaloLayers = 2
        // Form fields and chips are controls, not glass: a deeper inset gives their text a ground.
        let dark = glassTint.source == .system(.black)
        palette.fieldFill = ThemeColor(dark ? .black : .white, alpha: dark ? 0.45 : 0.6)
        // Cards and menus stay regular glass; over clear glass they need a deeper tint to read as
        // a layer and keep their titles at 4.5 to 1.
        palette.cardTint = ThemeColor(dark ? .black : .white, alpha: dark ? 0.78 : 0.72)
        return palette
    }
}
