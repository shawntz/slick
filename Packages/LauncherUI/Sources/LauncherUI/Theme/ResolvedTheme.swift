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
    /// The theme's accent at full strength: the prominent fill. The text caret takes it.
    public let accent: CGColor
    /// The tint for the panel glass, or nil under Reduce Transparency.
    public let glassTint: NSColor?
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
        accent = resolve(palette.prominent)

        var tint: NSColor?
        if !accessibility.reduceTransparency {
            tint = palette.glassTint.scaled(by: theme.clarity).nsColor
        }
        glassTint = tint
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
