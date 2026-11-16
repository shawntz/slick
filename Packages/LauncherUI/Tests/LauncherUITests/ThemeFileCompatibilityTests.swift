import AppKit
import Foundation
import Testing

@testable import LauncherUI

/// Theme files written before the glass style, the split layout, the rim, the shadow, the caret
/// colours, the run hints, the placeholder and empty symbol colours and the toast-only action bar
/// existed still load, and today's files hold every key.
@Suite(.timeLimit(.minutes(1)))
struct ThemeFileCompatibilityTests {
    /// Every key added for Spotlight and Glass, by the part of the file it sits in.
    static let addedKeys: [String: [String]] = [
        "panel": ["glassStyle", "layout", "fieldGap", "fieldCornerRadius", "rimWidth", "shadowRadius", "shadowOffset"],
        "queryRow": ["showsRootGlyph"],
        "list": ["showsRunHints"],
        "actionBar": ["showsOnlyForToasts"],
        "fonts": ["runHint"],
        "light": [
            "fieldTint", "fieldShade", "rim", "shadow", "caret", "caretGlow", "runHint", "textHaloLayers",
            "placeholder",
            "emptySymbol",
        ],
        "dark": [
            "fieldTint", "fieldShade", "rim", "shadow", "caret", "caretGlow", "runHint", "textHaloLayers",
            "placeholder",
            "emptySymbol",
        ],
    ]

    static func object(_ theme: Theme) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(theme)) as? [String: Any])
    }

    /// `theme` as a file from before the new keys: the same JSON with every added key removed.
    static func oldFile(_ theme: Theme) throws -> Data {
        var file = try object(theme)
        for (part, keys) in addedKeys {
            var values = try #require(file[part] as? [String: Any])
            for key in keys { values[key] = nil }
            file[part] = values
        }
        return try JSONSerialization.data(withJSONObject: file)
    }

    @Test func encodedStandardIsACompleteFile() throws {
        let file = try Self.object(.standard)
        for (part, keys) in Self.addedKeys {
            let values = try #require(file[part] as? [String: Any])
            for key in keys { #expect(values[key] != nil, "\(part).\(key)") }
        }
    }

    /// A file of each one-slab theme, made before the new keys, loads as the same theme: the new
    /// keys fall back to what those themes drew before.
    @Test(arguments: ["Standard", "Graphite", "Ocean", "Ember", "Violet"])
    func anOldFileLoadsAsItWasMade(_ name: String) throws {
        let theme = try #require(ThemeStore.builtInThemes.first { $0.name == name }?.theme)
        #expect(try JSONDecoder().decode(Theme.self, from: Self.oldFile(theme)) == theme)
    }

    /// Fallbacks that copy another value of the same file keep a user's own colours.
    @Test func anOldFileKeepsItsOwnCaretRunHintAndQueryRowTint() throws {
        var mine = Theme.standard
        mine.light.prominent = ThemeColor(red: 0x1A / 255, green: 0x4D / 255, blue: 0x99 / 255)
        mine.dark.accessory = ThemeColor(.label, alpha: 0.66)
        mine.dark.glassTint = ThemeColor(.black, alpha: 0.42)
        mine.fonts.accessory = ThemeFont(size: 13, weight: .medium)
        let loaded = try JSONDecoder().decode(Theme.self, from: Self.oldFile(mine))
        #expect(loaded.light.caret == mine.light.prominent)
        #expect(loaded.dark.runHint == mine.dark.accessory)
        #expect(loaded.dark.fieldTint == mine.dark.glassTint)
        #expect(loaded.fonts.runHint == mine.fonts.accessory)
        #expect(loaded.panel.layout == .single && loaded.panel.glassStyle == .regular)
        #expect(loaded.panel.rimWidth == 0 && loaded.panel.shadowRadius == 0)
        #expect(loaded.queryRow.showsRootGlyph && !loaded.list.showsRunHints)
        #expect(loaded.light.caretGlow.isEmpty && loaded.light.fieldShade.alpha == 0)
        #expect(loaded.light.textHaloLayers == 1)
        #expect(
            loaded.dark.placeholder == ThemeColor(.tertiaryLabel)
                && loaded.dark.emptySymbol == ThemeColor(.tertiaryLabel))
        #expect(!loaded.actionBar.showsOnlyForToasts)
    }

    @Test func spotlightAndGlassSurviveJSON() throws {
        for theme in [Theme.spotlight, .glass] {
            #expect(try JSONDecoder().decode(Theme.self, from: JSONEncoder().encode(theme)) == theme)
        }
        let file = String(decoding: try JSONEncoder().encode(Theme.spotlight), as: UTF8.self)
        #expect(file.contains(##""layout":"split""##))
        #expect(file.contains(##""caretGlow":["#A3DBFF@0.6","##))
    }

    @Test func aBadNewValueIsStillReported() throws {
        let folder = ThemeStoreTests.Folder()
        var file = try Self.object(.standard)
        var panel = try #require(file["panel"] as? [String: Any])
        panel["glassStyle"] = "frosted"
        file["panel"] = panel
        try folder.write(
            String(decoding: try JSONSerialization.data(withJSONObject: file), as: UTF8.self), to: "Odd.json")
        try folder.write(String(decoding: try Self.oldFile(.ocean), as: UTF8.self), to: "Old.json")
        let store = ThemeStore(folder: folder.url)
        #expect(store.problems.map(\.reason) == ["bad value at panel.glassStyle"])
        #expect(store.theme(named: "Old")?.theme == .ocean)
    }

    @Test func theSplitStackHoldsTheGap() {
        let spotlight = Theme.spotlight
        #expect(spotlight.glassHeight(contentHeight: 0) == 87)
        // Four rows of the reference: its stack exactly, with no action bar until a toast shows.
        #expect(spotlight.glassHeight(contentHeight: 214) == 87 + 10 + 214)
        #expect(spotlight.glassHeight(contentHeight: 214, showsToast: true) == 87 + 10 + 214 + 40)
        #expect(spotlight.maxGlassHeight == 87 + 10 + spotlight.panel.maxContentHeight + 40)
        var tall = spotlight
        tall.panel.fieldCornerRadius = 100
        #expect(tall.fieldCornerRadius == 43.5)
    }

    @Test func clearGlassResolvesWithNoTintAndFallsBackUnderReduceTransparency() {
        _ = NSApplication.shared
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: name)!
            let clear = ResolvedTheme(theme: .glass, appearance: appearance, accessibility: DisplayAccessibility())
            #expect(clear.glassStyle == .clear)
            #expect(clear.glassTint == nil && clear.fieldTint == nil)
            #expect(clear.card.tint != nil, "cards keep their tint")
            let opaque = ResolvedTheme(
                theme: .glass, appearance: appearance, accessibility: DisplayAccessibility(reduceTransparency: true))
            #expect(opaque.glassStyle == .regular && opaque.glassTint == nil)
            let standard = ResolvedTheme(
                theme: .standard, appearance: appearance, accessibility: DisplayAccessibility())
            #expect(standard.glassStyle == .regular && standard.rim == nil && standard.shadow == nil)
            #expect(standard.caret == standard.accent && standard.caretGlow.isEmpty)
        }
    }

    @Test func spotlightResolvesItsDecorationAndDropsTheShadeUnderReduceTransparency() {
        _ = NSApplication.shared
        let dark = NSAppearance(named: .darkAqua)!
        let spotlight = ResolvedTheme(theme: .spotlight, appearance: dark, accessibility: DisplayAccessibility())
        #expect(spotlight.fieldShade != nil && spotlight.rim != nil && spotlight.shadow != nil)
        #expect(spotlight.caretGlow.count == 3)
        #expect(abs((spotlight.fieldTint?.alphaComponent ?? 0) - 0.2) < 0.001)
        let opaque = ResolvedTheme(
            theme: .spotlight, appearance: dark, accessibility: DisplayAccessibility(reduceTransparency: true))
        #expect(opaque.fieldShade == nil && opaque.fieldTint == nil && opaque.glassTint == nil)
        let still = ResolvedTheme(
            theme: .spotlight, appearance: dark, accessibility: DisplayAccessibility(reduceMotion: true))
        #expect(still.motion.heightChange == 0 && still.motion.lensGlide == 0)
    }
}
