import LauncherUI

/// The parts of a ``Theme`` the appearance pane edits, read and written as plain values.
///
/// Every edit keeps the rest of the theme as it is, so a theme file written by hand keeps the
/// values the pane does not show.
extension Theme {
    /// The glass tint for an appearance.
    func glassTint(dark: Bool) -> ThemeColor {
        palette(dark: dark).glassTint
    }

    mutating func setGlassTint(_ color: ThemeColor, dark: Bool) {
        if dark { self.dark.glassTint = color } else { light.glassTint = color }
    }

    /// The accent colour, or nil when the theme follows the system accent.
    var accent: ThemeColor? {
        guard case .srgb(let red, let green, let blue) = light.prominent.source else { return nil }
        return ThemeColor(red: red, green: green, blue: blue)
    }

    /// Sets the accent, or follows the system accent for nil. Each colour that Standard takes from
    /// the system accent takes this one instead, at Standard's alpha.
    mutating func setAccent(_ accent: ThemeColor?) {
        light.applyAccent(accent, base: Theme.standard.light)
        dark.applyAccent(accent, base: Theme.standard.dark)
    }

    /// Row height of one-line rows. Two-line rows keep their extra height.
    var rowHeight: Double {
        get { list.rowHeight }
        set {
            let extra = list.twoLineRowHeight - list.rowHeight
            list.rowHeight = newValue
            list.twoLineRowHeight = newValue + extra
        }
    }

    /// The title size. Grid and card titles follow it by the same change.
    var titleSize: Double {
        get { fonts.title.size }
        set {
            let change = newValue - fonts.title.size
            fonts.title.size = newValue
            fonts.cardRow.size += change
            fonts.gridTitle.size += change
        }
    }

    /// The subtitle size. Accessories and grid subtitles follow it by the same change.
    var subtitleSize: Double {
        get { fonts.subtitle.size }
        set {
            let change = newValue - fonts.subtitle.size
            fonts.subtitle.size = newValue
            fonts.accessory.size += change
            fonts.gridSubtitle.size += change
        }
    }

    /// The search field's text size.
    var querySize: Double {
        get { fonts.query.size }
        set { fonts.query.size = newValue }
    }
}

extension ThemePalette {
    fileprivate mutating func applyAccent(_ accent: ThemeColor?, base: ThemePalette) {
        func pick(_ slot: ThemeColor) -> ThemeColor {
            guard slot.source == .system(.accent) else { return slot }
            return accent.map { $0.scaled(by: slot.alpha) } ?? slot
        }
        lensGlassTint = pick(base.lensGlassTint)
        link = pick(base.link)
        focusRing = pick(base.focusRing)
        prominent = pick(base.prominent)
        loadingBar = pick(base.loadingBar)
    }
}

extension ThemeColor {
    /// The colour's sRGB components, or nil for a system colour.
    var srgb: (red: Double, green: Double, blue: Double)? {
        guard case .srgb(let red, let green, let blue) = source else { return nil }
        return (red, green, blue)
    }
}
