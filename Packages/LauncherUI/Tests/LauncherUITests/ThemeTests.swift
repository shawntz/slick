import AppKit
import Foundation
import Testing

@testable import LauncherUI

@Suite(.timeLimit(.minutes(1)))
struct ThemeTests {
    @Test func standardThemeSurvivesJSON() throws {
        let data = try JSONEncoder().encode(Theme.standard)
        let decoded = try JSONDecoder().decode(Theme.self, from: data)
        #expect(decoded == Theme.standard)
    }

    @Test func coloursEncodeAsShortStrings() throws {
        let data = try JSONEncoder().encode([
            ThemeColor(.secondaryLabel, alpha: 0.9), ThemeColor(red: 1, green: 0.5, blue: 0, alpha: 0.35),
        ])
        #expect(String(decoding: data, as: UTF8.self) == ##"["secondaryLabel@0.9","#FF8000@0.35"]"##)
    }

    @Test(arguments: ["label", "accent@0.25", "#1E90FF", "#000000@0.35"])
    func colourStringsRoundTrip(_ text: String) throws {
        #expect(ThemeColor(text)?.description == text)
    }

    @Test(arguments: ["", "label@2", "#12345", "#GGGGGG", "notAColour", "label@x"])
    func badColourStringsAreRejected(_ text: String) {
        #expect(ThemeColor(text) == nil)
    }

    @Test func glassHeightIsQueryRowAloneWithoutContent() {
        let theme = Theme.standard
        #expect(theme.glassHeight(contentHeight: 0) == theme.queryRow.height)
        #expect(theme.glassHeight(contentHeight: 100) == theme.queryRow.height + 100 + theme.actionBar.height)
        #expect(theme.glassHeight(contentHeight: 10_000) == theme.maxGlassHeight)
    }

    @Test func clarityScalesTheTint() {
        _ = NSApplication.shared
        var theme = Theme.standard
        theme.clarity = 2
        let dark = NSAppearance(named: .darkAqua)!
        let resolved = ResolvedTheme(theme: theme, appearance: dark, accessibility: DisplayAccessibility())
        let expected = min(1, Theme.standard.dark.glassTint.alpha * 2)
        #expect(abs((resolved.glassTint?.alphaComponent ?? 0) - expected) < 0.001)
    }

    @Test func reduceTransparencyDropsTheTint() {
        _ = NSApplication.shared
        let resolved = ResolvedTheme(
            theme: .standard, appearance: NSAppearance(named: .aqua)!,
            accessibility: DisplayAccessibility(reduceTransparency: true)
        )
        #expect(resolved.glassTint == nil)
    }

    @Test func reduceMotionStopsEveryAnimation() {
        _ = NSApplication.shared
        var theme = Theme.standard
        theme.motion.summonRampFrames = 3
        let resolved = ResolvedTheme(
            theme: theme, appearance: NSAppearance(named: .aqua)!,
            accessibility: DisplayAccessibility(reduceMotion: true))
        #expect(
            resolved.motion
                == MotionMetrics(
                    lensGlide: 0, heightChange: 0, summonRampFrames: 0, toastFade: 0, scrollIndicatorFade: 0,
                    cardFade: 0, dimFade: 0, hudFade: 0, loadingSweep: 0))
    }

    @Test func increaseContrastStopsDimmingUnmatchedText() {
        _ = NSApplication.shared
        let appearance = NSAppearance(named: .aqua)!
        let normal = ResolvedTheme(theme: .standard, appearance: appearance, accessibility: DisplayAccessibility())
        let contrast = ResolvedTheme(
            theme: .standard, appearance: appearance, accessibility: DisplayAccessibility(increaseContrast: true))
        #expect(normal.unmatchedTitle.alpha < normal.title.alpha)
        #expect(contrast.unmatchedTitle.alpha == contrast.title.alpha)
    }
}
