import AppKit
import CoreText

/// Resolves theme colours for one appearance, applying Increase Contrast.
struct ColorResolver {
    let appearance: NSAppearance
    let increaseContrast: Bool

    /// The colour resolved for the appearance. Under Increase Contrast its alpha is multiplied by
    /// `boost`, so faint fills and secondary text get stronger.
    func callAsFunction(_ color: ThemeColor, boost: Double = 1) -> CGColor {
        color.scaled(by: increaseContrast ? boost : 1).cgColor(in: appearance)
    }

    /// The same, as a static `NSColor` for AppKit text.
    func ns(_ color: ThemeColor, boost: Double = 1) -> NSColor {
        NSColor(cgColor: self(color, boost: boost)) ?? .labelColor
    }
}

/// Fonts and colours for grid cells.
public struct ResolvedGridStyle {
    public let titleFont: CTFont
    public let subtitleFont: CTFont
    public let tileFill: CGColor

    init(_ theme: Theme, _ palette: ThemePalette, _ resolve: ColorResolver) {
        titleFont = theme.fonts.gridTitle.ctFont
        subtitleFont = theme.fonts.gridSubtitle.ctFont
        tileFill = resolve(palette.tileFill, boost: 1.6)
    }
}

/// Fonts and colours for the detail pane, its Markdown and its metadata table.
public struct ResolvedDetailStyle {
    public let textFont: NSFont
    public let boldFont: NSFont
    public let italicFont: NSFont
    public let monospacedFont: NSFont
    /// Heading fonts, level 1 first.
    public let headingFonts: [NSFont]
    public let metadataLabelFont: CTFont
    public let metadataValueFont: CTFont
    public let text: NSColor
    public let secondaryText: NSColor
    public let link: NSColor
    public let codeFill: NSColor
    /// The same colours for Core Text.
    public let textColor: CGColor
    public let secondaryColor: CGColor
    public let linkColor: CGColor

    init(_ theme: Theme, _ palette: ThemePalette, _ resolve: ColorResolver) {
        let fonts = theme.fonts
        textFont = fonts.detailText.nsFont
        let manager = NSFontManager.shared
        boldFont = manager.convert(textFont, toHaveTrait: .boldFontMask)
        italicFont = manager.convert(textFont, toHaveTrait: .italicFontMask)
        monospacedFont = fonts.detailMonospaced.nsFont
        headingFonts = fonts.markdownHeadings.isEmpty ? [boldFont] : fonts.markdownHeadings.map(\.nsFont)
        metadataLabelFont = fonts.metadataLabel.ctFont
        metadataValueFont = fonts.metadataValue.ctFont
        textColor = resolve(palette.detailText)
        secondaryColor = resolve(palette.subtitle, boost: 1.25)
        linkColor = resolve(palette.link)
        text = NSColor(cgColor: textColor) ?? .labelColor
        secondaryText = NSColor(cgColor: secondaryColor) ?? .secondaryLabelColor
        link = NSColor(cgColor: linkColor) ?? .linkColor
        codeFill = resolve.ns(palette.codeFill, boost: 1.6)
    }
}

/// Fonts and colours for the action card, the confirm card and dropdown menus.
public struct ResolvedCardStyle {
    public let filterFont: NSFont
    public let rowFont: CTFont
    public let sectionFont: CTFont
    public let confirmTitleFont: NSFont
    public let confirmMessageFont: NSFont
    public let buttonFont: CTFont
    /// The tint of the card's nested glass, or nil under Reduce Transparency.
    public let tint: NSColor?
    public let selection: CGColor
    public let destructive: CGColor
    public let prominent: CGColor
    public let onProminent: CGColor
    public let onProminentKeycap: CGColor

    init(_ theme: Theme, _ palette: ThemePalette, _ resolve: ColorResolver, reduceTransparency: Bool) {
        let fonts = theme.fonts
        filterFont = fonts.cardFilter.nsFont
        rowFont = fonts.cardRow.ctFont
        sectionFont = fonts.cardSection.ctFont
        confirmTitleFont = fonts.confirmTitle.nsFont
        confirmMessageFont = fonts.confirmMessage.nsFont
        buttonFont = fonts.button.ctFont
        tint = reduceTransparency ? nil : palette.cardTint.scaled(by: theme.clarity).nsColor
        selection = resolve(palette.cardSelection, boost: 1.6)
        destructive = resolve(palette.destructive)
        prominent = resolve(palette.prominent)
        onProminent = resolve(palette.onProminent)
        onProminentKeycap = resolve(palette.onProminentKeycap, boost: 1.5)
    }
}

/// Fonts and colours for forms and the query row's chips.
public struct ResolvedFormStyle {
    public let labelFont: NSFont
    public let controlFont: NSFont
    public let messageFont: NSFont
    public let chipFont: NSFont
    public let fieldFill: CGColor
    public let focusRing: CGColor
    public let error: NSColor
    public let prominent: CGColor
    public let onProminent: CGColor

    init(_ theme: Theme, _ palette: ThemePalette, _ resolve: ColorResolver) {
        let fonts = theme.fonts
        labelFont = fonts.formLabel.nsFont
        controlFont = fonts.formControl.nsFont
        messageFont = fonts.formMessage.nsFont
        chipFont = fonts.chip.nsFont
        fieldFill = resolve(palette.fieldFill, boost: 1.8)
        focusRing = resolve(palette.focusRing, boost: 1.3)
        error = resolve.ns(palette.error)
        prominent = resolve(palette.prominent)
        onProminent = resolve(palette.onProminent)
    }
}

/// Fonts and colours for the empty state, the loading bar and the HUD.
public struct ResolvedFeedbackStyle {
    public let emptyTitleFont: NSFont
    public let emptyHintFont: NSFont
    public let hudFont: NSFont
    public let loadingBar: CGColor
    /// The tint of the HUD's glass, or nil under Reduce Transparency.
    public let hudTint: NSColor?

    init(_ theme: Theme, _ palette: ThemePalette, _ resolve: ColorResolver, reduceTransparency: Bool) {
        let fonts = theme.fonts
        emptyTitleFont = fonts.emptyTitle.nsFont
        emptyHintFont = fonts.emptyHint.nsFont
        hudFont = fonts.hud.nsFont
        loadingBar = resolve(palette.loadingBar)
        hudTint = reduceTransparency ? nil : palette.hudTint.scaled(by: theme.clarity).nsColor
    }
}
