import AppKit
import CoreText

/// A theme resolved for one appearance and one set of accessibility settings: fonts as `CTFont`
/// and colours as `CGColor`, ready for Core Text.
///
/// Resolving costs microseconds per colour, so views build this once when the appearance or the
/// settings change and never per row or per keystroke.
public struct ResolvedTheme {
    public let theme: Theme
    public let appearance: NSAppearance
    public let isDark: Bool
    public let accessibility: DisplayAccessibility
    public let palette: ThemePalette
    /// The theme's motion with every duration set to zero under Reduce Motion.
    public let motion: MotionMetrics

    public let queryFont: NSFont
    public let titleFont: CTFont
    public let subtitleFont: CTFont
    public let accessoryFont: CTFont
    public let sectionHeaderFont: CTFont
    public let tagFont: CTFont
    public let keycapFont: CTFont
    public let runHintFont: CTFont

    public let title: CGColor
    /// Title characters that did not match while a query is active.
    public let unmatchedTitle: CGColor
    public let subtitle: CGColor
    public let accessory: CGColor
    public let sectionHeader: CGColor
    public let ghostText: CGColor
    public let hairline: CGColor
    public let lensFill: CGColor
    public let iconPlaceholder: CGColor
    public let keycapFill: CGColor
    public let keycapText: CGColor
    public let scrollIndicator: CGColor
    public let textHalo: CGColor?
    /// How many times the halo is laid down, at least one.
    public let textHaloLayers: Int
    /// The theme's accent at full strength: the prominent fill.
    public let accent: CGColor
    /// The text caret of every field in the panel.
    public let caret: CGColor
    /// The glow around the query field's caret, top to bottom. Empty for none.
    public let caretGlow: [CGColor]
    public let runHint: CGColor
    /// The query field's placeholder, left dynamic so the field keeps its vibrancy.
    public let placeholder: NSColor
    /// The large symbol of an empty state, left dynamic as the placeholder is.
    public let emptySymbol: NSColor
    /// The panel glass's style: the theme's, or regular under Reduce Transparency, where the
    /// system makes the regular glass opaque.
    public let glassStyle: NSGlassEffectView.Style
    /// The tint for the panel glass, or the results container in the split layout. Nil under
    /// Reduce Transparency and for a tint with no alpha.
    public let glassTint: NSColor?
    /// The tint for the query row's glass in the split layout. Nil as `glassTint` is.
    public let fieldTint: NSColor?
    /// The shade over the query row's glass in the split layout, at its top edge. Nil under
    /// Reduce Transparency and when the theme has none.
    public let fieldShade: CGColor?
    /// The bright line on the lower half of the glass's edge, or nil for none.
    public let rim: CGColor?
    /// The shadow under the glass, or nil for none.
    public let shadow: CGColor?
    public let lensGlassTint: NSColor

    public let grid: ResolvedGridStyle
    public let detail: ResolvedDetailStyle
    public let card: ResolvedCardStyle
    public let form: ResolvedFormStyle
    public let feedback: ResolvedFeedbackStyle

    public init(theme: Theme, appearance: NSAppearance, accessibility: DisplayAccessibility) {
        self.theme = theme
        self.appearance = appearance
        self.accessibility = accessibility
        isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let palette = theme.palette(dark: isDark)
        self.palette = palette

        var motion = theme.motion
        if accessibility.reduceMotion {
            motion.lensGlide = 0
            motion.heightChange = 0
            motion.summonRampFrames = 0
            motion.toastFade = 0
            motion.scrollIndicatorFade = 0
            motion.cardFade = 0
            motion.dimFade = 0
            motion.hudFade = 0
            motion.loadingSweep = 0
        }
        self.motion = motion

        let fonts = theme.fonts
        queryFont = fonts.query.nsFont
        titleFont = fonts.title.ctFont
        subtitleFont = fonts.subtitle.ctFont
        accessoryFont = fonts.accessory.ctFont
        sectionHeaderFont = fonts.sectionHeader.ctFont
        tagFont = fonts.tag.ctFont
        keycapFont = fonts.keycap.ctFont
        runHintFont = fonts.runHint.ctFont

        // Increase Contrast: no dimmed text, and stronger strokes and fills.
        let contrast = accessibility.increaseContrast
        let resolve = ColorResolver(appearance: appearance, increaseContrast: contrast)
        title = resolve(palette.title)
        unmatchedTitle = resolve(palette.title.scaled(by: contrast ? 1 : palette.unmatchedTitleAlpha))
        subtitle = resolve(palette.subtitle, boost: 1.25)
        accessory = resolve(palette.accessory, boost: 1.25)
        sectionHeader = resolve(palette.sectionHeader, boost: 1.25)
        ghostText = resolve(palette.ghostText, boost: 1.25)
        hairline = resolve(palette.hairline, boost: 2)
        lensFill = resolve(palette.lensFill, boost: 1.6)
        iconPlaceholder = resolve(palette.iconPlaceholder, boost: 1.5)
        keycapFill = resolve(palette.keycapFill, boost: 1.6)
        keycapText = resolve(palette.keycapText, boost: 1.25)
        scrollIndicator = resolve(palette.scrollIndicator, boost: 1.5)
        textHalo = palette.textHalo.map { resolve($0) }
        textHaloLayers = max(1, min(4, palette.textHaloLayers))
        accent = resolve(palette.prominent)
        caret = resolve(palette.caret)
        caretGlow = palette.caretGlow.filter { $0.alpha > 0 }.map { resolve($0) }
        runHint = resolve(palette.runHint, boost: 1.25)
        placeholder = palette.placeholder.nsColor
        emptySymbol = palette.emptySymbol.nsColor

        let opaque = accessibility.reduceTransparency
        glassStyle = !opaque && theme.panel.glassStyle == .clear ? .clear : .regular
        // A tint that would be invisible is no tint at all, so clear glass gets none.
        func tint(_ color: ThemeColor) -> NSColor? {
            let scaled = color.scaled(by: theme.clarity)
            return opaque || scaled.alpha <= 0 ? nil : scaled.nsColor
        }
        glassTint = tint(palette.glassTint)
        fieldTint = tint(palette.fieldTint)
        fieldShade = opaque || palette.fieldShade.alpha <= 0 ? nil : resolve(palette.fieldShade)
        rim = theme.panel.rimWidth > 0 && palette.rim.alpha > 0 ? resolve(palette.rim) : nil
        shadow = theme.panel.shadowRadius > 0 && palette.shadow.alpha > 0 ? resolve(palette.shadow) : nil
        lensGlassTint = palette.lensGlassTint.nsColor

        let clear = accessibility.reduceTransparency
        grid = ResolvedGridStyle(theme, palette, resolve)
        detail = ResolvedDetailStyle(theme, palette, resolve)
        card = ResolvedCardStyle(theme, palette, resolve, reduceTransparency: clear)
        form = ResolvedFormStyle(theme, palette, resolve)
        feedback = ResolvedFeedbackStyle(theme, palette, resolve, reduceTransparency: clear)
    }

    /// The colours of a tag: its text, and its capsule fill. The text is the tag colour pulled
    /// toward the label colour by `tagTextDepth`, because a saturated colour on its own tint is too
    /// faint to read.
    public func tagColors(_ color: ThemeColor) -> (text: CGColor, fill: CGColor) {
        let base = color.cgColor(in: appearance)
        let fill = color.scaled(by: palette.tagFillAlpha).cgColor(in: appearance)
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
            let tint = base.converted(to: sRGB, intent: .defaultIntent, options: nil)?.components,
            let label = title.converted(to: sRGB, intent: .defaultIntent, options: nil)?.components,
            tint.count == 4, label.count == 4
        else { return (base, fill) }
        let depth = CGFloat(palette.tagTextDepth)
        let mixed = (0..<3).map { tint[$0] * (1 - depth) + label[$0] * depth }
        return (CGColor(srgbRed: mixed[0], green: mixed[1], blue: mixed[2], alpha: tint[3]), fill)
    }
}

extension ResolvedTheme {
    /// Whether `other` styles views the same: the same theme, appearance and display settings.
    public func isSameStyle(as other: ResolvedTheme) -> Bool {
        theme == other.theme && isDark == other.isDark && accessibility == other.accessibility
            && appearance.name == other.appearance.name
    }
}
