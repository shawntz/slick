import AppKit
import Foundation
import Testing

@testable import LauncherUI

@Suite(.timeLimit(.minutes(1)))
struct ThemeStoreTests {
    /// A fresh temporary folder per test, removed when the test ends.
    final class Folder {
        let url = FileManager.default.temporaryDirectory.appending(path: "theme-store-" + UUID().uuidString)

        deinit {
            try? FileManager.default.removeItem(at: url)
        }

        func write(_ text: String, to name: String) throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url.appending(path: name))
        }
    }

    static let builtInNames = ThemeStore.builtInThemes.map(\.name)

    // MARK: Built-in themes

    @Test func builtInsDifferInTintLensAndAccent() {
        let themes = ThemeStore.builtInThemes.map(\.theme)
        #expect(Self.builtInNames == ["Standard", "Graphite", "Ocean", "Ember", "Violet"])
        #expect(Set(themes.map(\.dark.glassTint)).count == themes.count)
        // Coloured light tints missed glass rule 5 over a dark backdrop, so light glass stays white.
        #expect(Set(themes.map(\.light.glassTint)) == [Theme.standard.light.glassTint])
        #expect(Set(themes.map(\.light.prominent)).count == themes.count)
        #expect(Set(themes.map { "\($0.lens.style) \($0.lens.cornerRadius)" }).count == themes.count)
        #expect(Set(themes.map(\.lens.style)) == [.glass, .fill])
    }

    @Test func violetTakesTheIconPalette() {
        let violet = Theme.violet
        #expect(violet.light.prominent == ThemeColor(red: 0x87 / 255, green: 0x43 / 255, blue: 0xFA / 255))
        #expect(violet.dark.prominent == violet.light.prominent)
        #expect(violet.dark.glassTint.description == "#24064C@0.55")
        #expect(violet.dark.lensGlassTint.description.hasPrefix("#A522FC@"))
        #expect(violet.light.focusRing.description.hasPrefix("#8743FA@"))
    }

    /// White text on every built-in accent reaches 4.5:1, so a prominent button stays readable.
    @Test func builtInAccentsCarryWhiteText() {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        for named in ThemeStore.builtInThemes.dropFirst() {
            guard case .srgb(let red, let green, let blue) = named.theme.light.prominent.source else {
                Issue.record("\(named.name) has no sRGB accent")
                continue
            }
            let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
            #expect(1.05 / (luminance + 0.05) >= 4.5, "\(named.name)")
        }
    }

    @Test func builtInsSurviveJSON() throws {
        for named in ThemeStore.builtInThemes {
            let data = try JSONEncoder().encode(named.theme)
            #expect(try JSONDecoder().decode(Theme.self, from: data) == named.theme, "\(named.name)")
        }
    }

    @Test func builtInsKeepTheThemeRules() {
        _ = NSApplication.shared
        for named in ThemeStore.builtInThemes {
            checkRules(named)
        }
    }

    private func checkRules(_ named: NamedTheme) {
        var theme = named.theme
        #expect(theme.glassHeight(contentHeight: 0) == theme.queryRow.height)
        #expect(theme.glassHeight(contentHeight: 10_000) == theme.maxGlassHeight)
        let dark = NSAppearance(named: .darkAqua)!
        let light = NSAppearance(named: .aqua)!
        theme.clarity = 2
        let clear = ResolvedTheme(theme: theme, appearance: dark, accessibility: DisplayAccessibility())
        #expect(abs((clear.glassTint?.alphaComponent ?? 0) - min(1, named.theme.dark.glassTint.alpha * 2)) < 0.001)
        let opaque = ResolvedTheme(
            theme: named.theme, appearance: light, accessibility: DisplayAccessibility(reduceTransparency: true))
        #expect(opaque.glassTint == nil)
        let still = ResolvedTheme(
            theme: named.theme, appearance: light, accessibility: DisplayAccessibility(reduceMotion: true))
        #expect(still.motion.lensGlide == 0 && still.motion.heightChange == 0)
        let contrast = ResolvedTheme(
            theme: named.theme, appearance: light, accessibility: DisplayAccessibility(increaseContrast: true))
        #expect(contrast.unmatchedTitle.alpha == contrast.title.alpha)
    }

    // MARK: Listing and selecting

    @Test func listsUserThemesAfterBuiltInsAndSkipsCorruptFiles() throws {
        let folder = Folder()
        var dusk = Theme.standard
        dusk.clarity = 1.5
        try folder.write(String(decoding: try JSONEncoder().encode(dusk), as: UTF8.self), to: "Dusk.json")
        try folder.write("{\"panel\": 3}", to: "Broken.json")
        try folder.write("not json", to: "Garbage.json")
        try folder.write("{}", to: "graphite.json")
        try folder.write("ignored", to: "notes.txt")

        let store = ThemeStore(folder: folder.url)
        #expect(store.themes.map(\.name) == Self.builtInNames + ["Dusk"])
        #expect(store.theme(named: "dusk")?.theme == dusk)
        #expect(store.problems.map(\.file.lastPathComponent) == ["Broken.json", "Garbage.json", "graphite.json"])
        #expect(store.problems.first?.reason == "wrong value at panel")
        #expect(store.problems[1].reason == "not JSON")
        #expect(store.selectedName == "Standard" && store.current == .standard)
    }

    @Test func selectsByNameAndTellsObservers() {
        let folder = Folder()
        let store = ThemeStore(folder: folder.url, selecting: "ocean")
        #expect(store.selectedName == "Ocean" && store.current == .ocean)
        var seen: [ThemeStore.Changes] = []
        let observer = store.addObserver { seen.append($0) }

        #expect(store.select("Ember"))
        #expect(store.current == .ember)
        #expect(!store.select("Missing"))
        #expect(store.selectedName == "Ember")
        store.select("Ember")
        store.removeObserver(observer)
        store.select("Standard")
        #expect(seen == [.current])
    }

    @Test func missingSelectionFallsBackToStandard() {
        let folder = Folder()
        let store = ThemeStore(folder: folder.url, selecting: "Deleted Theme")
        #expect(store.selectedName == "Standard" && store.current == .standard)
    }

    // MARK: Saving, importing and exporting

    @Test func savesAnEditedThemeAndReloadsIt() throws {
        let folder = Folder()
        let store = ThemeStore(folder: folder.url)
        var seen: [ThemeStore.Changes] = []
        store.addObserver { seen.append($0) }
        var edited = Theme.graphite
        edited.list.rowHeight = 40

        try store.save(edited, as: "  Compact  ")
        #expect(store.themes.last == NamedTheme(name: "Compact", theme: edited, isBuiltIn: false))
        #expect(FileManager.default.fileExists(atPath: folder.url.appending(path: "Compact.json").path))
        #expect(seen == [.list])

        store.select("Compact")
        edited.list.rowHeight = 36
        try store.save(edited, as: "compact")
        #expect(store.current.list.rowHeight == 36)
        #expect(seen.last == [.list, .current])
        #expect(ThemeStore(folder: folder.url, selecting: "Compact").current == edited)

        #expect(throws: ThemeStoreError.builtInName("Standard")) { try store.save(edited, as: "standard") }
        #expect(throws: ThemeStoreError.invalidName("a/b")) { try store.save(edited, as: "a/b") }
        #expect(throws: ThemeStoreError.invalidName(" ")) { try store.save(edited, as: " ") }
    }

    @Test func deletingTheSelectedThemeFallsBackToStandard() throws {
        let folder = Folder()
        let store = ThemeStore(folder: folder.url)
        try store.save(.ember, as: "Warm")
        store.select("Warm")
        try store.delete("Warm")
        #expect(store.selectedName == "Standard" && store.current == .standard)
        #expect(store.theme(named: "Warm") == nil)
        #expect(throws: ThemeStoreError.builtInName("Ocean")) { try store.delete("Ocean") }
        #expect(throws: ThemeStoreError.unknownTheme("Warm")) { try store.delete("Warm") }
    }

    @Test func importsWithAUniqueNameAndExportsAReadableFile() throws {
        let folder = Folder()
        let outside = Folder()
        let store = ThemeStore(folder: folder.url)
        let exported = outside.url.appending(path: "Ocean.json")
        try FileManager.default.createDirectory(at: outside.url, withIntermediateDirectories: true)

        try store.exportTheme(named: "Ocean", to: exported)
        #expect(try JSONDecoder().decode(Theme.self, from: Data(contentsOf: exported)) == .ocean)
        #expect(try store.importTheme(from: exported) == "Ocean 2")
        #expect(try store.importTheme(from: exported) == "Ocean 3")
        #expect(store.theme(named: "Ocean 3")?.theme == .ocean)

        try outside.write("{\"clarity\": 1}", to: "Partial.json")
        let partial = outside.url.appending(path: "Partial.json")
        #expect(throws: ThemeStoreError.unreadable(partial, reason: "missing panel")) {
            try store.importTheme(from: partial)
        }
        #expect(throws: ThemeStoreError.unknownTheme("Nope")) { try store.exportTheme(named: "Nope", to: exported) }
    }

    @Test func reloadPicksUpFilesChangedOnDisk() throws {
        let folder = Folder()
        let store = ThemeStore(folder: folder.url)
        try store.save(.graphite, as: "Mine")
        store.select("Mine")
        var seen: [ThemeStore.Changes] = []
        store.addObserver { seen.append($0) }

        try folder.write(String(decoding: try JSONEncoder().encode(Theme.ember), as: UTF8.self), to: "Mine.json")
        store.reload()
        #expect(store.current == .ember)
        try FileManager.default.removeItem(at: folder.url.appending(path: "Mine.json"))
        store.reload()
        #expect(store.selectedName == "Standard")
        #expect(seen == [[.list, .current], [.list, .current]])
    }
}
