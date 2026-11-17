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

    /// The themes that share Standard's one slab of regular glass and differ in colour alone.
    static var recolours: [Theme] {
        ThemeStore.builtInThemes.map(\.theme).filter { $0.panel.layout == .single && $0.panel.glassStyle == .regular }
    }

    @Test func builtInsComeInOrderWithASummaryEach() {
        #expect(Self.builtInNames == ["Standard", "Graphite", "Ocean", "Ember", "Violet", "Spotlight", "Glass"])
        for named in ThemeStore.builtInThemes {
            #expect(named.isBuiltIn && named.summary.hasSuffix(".") && named.summary.count > 20, "\(named.name)")
        }
    }

    @Test func recoloursDifferInTintLensAndAccent() {
        let themes = Self.recolours
        #expect(themes.count == 5)
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

    /// Spotlight and Glass change the glass itself, not its colour, and keep the system accent.
    @Test func spotlightAndGlassChangeTheGlass() {
        let clear = Theme.glass
        #expect(clear.panel.glassStyle == .clear && clear.panel.layout == .single)
        #expect(clear.light.glassTint.alpha == 0 && clear.dark.glassTint.alpha == 0)
        #expect(clear.clarity == 1, "clarity also scales the card and HUD tints")
        #expect(clear.light.textHalo != nil && clear.dark.textHalo != nil)
        #expect(
            clear.panel.width == Theme.standard.panel.width && clear.list.rowHeight == Theme.standard.list.rowHeight)
        let spotlight = Theme.spotlight
        #expect(spotlight.panel.layout == .split && spotlight.panel.glassStyle == .regular)
        #expect(spotlight.list.showsRunHints && !spotlight.queryRow.showsRootGlyph)
        #expect(spotlight.fieldCornerRadius == spotlight.queryRow.height / 2, "the query row is a capsule")
        for palette in [spotlight.light, spotlight.dark] {
            for color in [palette.glassTint, palette.fieldTint, palette.fieldShade, palette.lensFill] {
                #expect([.system(.black), .system(.white)].contains(color.source), "neutral glass: \(color)")
            }
        }
        for theme in [spotlight, clear] { #expect(theme.light.prominent.source == .system(.accent)) }
    }

    /// White text on every built-in accent reaches 4.5:1, so a prominent button stays readable.
    /// Themes that follow the system accent, as Standard does, are left to the system.
    @Test func builtInAccentsCarryWhiteText() {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        for named in ThemeStore.builtInThemes where named.theme.light.prominent.source != .system(.accent) {
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
        #expect(theme.glassHeight(contentHeight: 10_000, showsToast: true) == theme.maxGlassHeight)
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

    @Test func aNameAnEarlierBuildStoredSelectsTheRenamedTheme() {
        let folder = Folder()
        let spotlight = ThemeStore(folder: folder.url, selecting: "Beam")
        #expect(spotlight.selectedName == "Spotlight" && spotlight.current == .spotlight)
        let glass = ThemeStore(folder: folder.url, selecting: "clear")
        #expect(glass.selectedName == "Glass" && glass.current == .glass)
        #expect(glass.select("Beam"))
        #expect(glass.selectedName == "Spotlight")
        #expect(ThemeStore.currentName(for: "BEAM") == "Spotlight")
        #expect(ThemeStore.currentName(for: "Ocean") == "Ocean")
        #expect(
            ThemeStore.builtInThemes.first { $0.name == "Spotlight" }?.summary
                == "Looks like Spotlight in macOS 27. The search field is a capsule of glass, and the results show in "
                + "a separate panel below it.")
        let glassSummary = ThemeStore.builtInThemes.first { $0.name == "Glass" }?.summary ?? ""
        #expect(glassSummary.hasPrefix("The system's clear glass with no tint"))
        #expect(glassSummary.contains("harder to read over a busy or bright window"))
    }

    /// A file with a built-in theme's name holds the user's changes to that theme. A file with a
    /// name the theme had in an earlier build is still skipped, so the old name never changes it.
    @Test func aFileWithABuiltInNameChangesItAndAFormerNameIsSkipped() throws {
        let folder = Folder()
        let file = String(decoding: try JSONEncoder().encode(Theme.graphite), as: UTF8.self)
        for name in ["Spotlight", "glass", "Beam", "Clear", "Mine"] {
            try folder.write(file, to: "\(name).json")
        }
        let store = ThemeStore(folder: folder.url)
        #expect(store.themes.map(\.name) == Self.builtInNames + ["Mine"])
        #expect(Set(store.problems.map(\.file.lastPathComponent)) == ["Beam.json", "Clear.json"])
        for name in ["Spotlight", "Glass"] {
            let named = try #require(store.theme(named: name))
            #expect(named.isBuiltIn && named.isCustomized && named.theme == .graphite, "\(name)")
        }
        #expect(store.theme(named: "Beam")?.isBuiltIn == true)
        #expect(store.theme(named: "Beam")?.name == "Spotlight")
        #expect(ThemeStore.builtInThemes.first { $0.name == "Spotlight" }?.theme == .spotlight, "as it ships")
    }

    /// Before, a file named like a built-in theme was skipped as a duplicate and listed as a
    /// problem. Now it is the theme's changed version, and the store selects that version.
    @Test func aFileNamedLikeABuiltInThemeIsNoLongerAProblem() throws {
        let folder = Folder()
        try folder.write(String(decoding: try JSONEncoder().encode(Theme.ember), as: UTF8.self), to: "Standard.json")
        let store = ThemeStore(folder: folder.url)
        #expect(store.problems.isEmpty)
        #expect(store.themes.map(\.name) == Self.builtInNames)
        #expect(store.selectedName == "Standard" && store.current == .ember)
        #expect(store.theme(named: "Standard")?.theme == .ember)
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

    /// Standard as the store lists it, with the user's changes, takes over, not Standard as it ships.
    @Test func deletingTheSelectedThemeFallsBackToTheChangedStandard() throws {
        let folder = Folder()
        var mine = Theme.standard
        mine.clarity = 1.7
        try folder.write(String(decoding: try JSONEncoder().encode(mine), as: UTF8.self), to: "Standard.json")
        let store = ThemeStore(folder: folder.url)
        try store.save(.ember, as: "Warm")
        store.select("Warm")
        try store.delete("Warm")
        #expect(store.selectedName == "Standard")
        #expect(store.current == mine)
    }

    // MARK: Changing a theme

    static func changedStandard(clarity: Double = 1.5) -> Theme {
        var theme = Theme.standard
        theme.clarity = clarity
        theme.list.rowHeight = 44
        return theme
    }

    @Test func updatingABuiltInThemeKeepsTheChangesInAFileNamedAfterIt() throws {
        let folder = Folder()
        let store = ThemeStore(folder: folder.url)
        var seen: [ThemeStore.Changes] = []
        store.addObserver { seen.append($0) }
        let changed = Self.changedStandard()

        try store.update(changed, for: "standard")
        #expect(store.current == changed, "Standard is selected, so the launcher draws the change")
        #expect(store.selectedName == "Standard")
        #expect(seen == [[.list, .current]])
        let named = try #require(store.theme(named: "Standard"))
        #expect(named.isBuiltIn && named.isCustomized && named.theme == changed)
        #expect(named.summary == ThemeStore.builtInThemes[0].summary)
        #expect(ThemeStore.builtInThemes[0].theme == .standard && !ThemeStore.builtInThemes[0].isCustomized)
        #expect(FileManager.default.fileExists(atPath: folder.url.appending(path: "Standard.json").path))
        #expect(store.themes.map(\.name) == Self.builtInNames, "no new theme is listed")

        // The next launch reads the change back and selects it.
        let next = ThemeStore(folder: folder.url, selecting: "Standard")
        #expect(next.problems.isEmpty)
        #expect(next.theme(named: "Standard")?.isCustomized == true)
        #expect(next.current == changed)
        #expect(next.themes.map(\.name) == Self.builtInNames)

        #expect(throws: ThemeStoreError.unknownTheme("Nope")) { try store.update(changed, for: "Nope") }
        #expect(throws: ThemeStoreError.builtInName("Standard")) { try store.save(changed, as: "Standard") }
    }

    @Test func aChangeToAThemeThatIsNotSelectedLeavesTheLauncherAlone() throws {
        let folder = Folder()
        let store = ThemeStore(folder: folder.url, selecting: "Graphite")
        var seen: [ThemeStore.Changes] = []
        store.addObserver { seen.append($0) }
        var changed = Theme.ocean
        changed.clarity = 0.4

        try store.update(changed, for: "Ocean")
        #expect(store.current == .graphite)
        #expect(seen == [.list], "only the list changed")
        #expect(store.select("Ocean"))
        #expect(store.current == changed)
        // A name an earlier build used finds the theme it was renamed to.
        try store.update(.graphite, for: "Beam")
        #expect(store.theme(named: "Spotlight")?.theme == .graphite)
        #expect(FileManager.default.fileExists(atPath: folder.url.appending(path: "Spotlight.json").path))
        #expect(!FileManager.default.fileExists(atPath: folder.url.appending(path: "Beam.json").path))
    }

    @Test func aBuiltInThemeEqualToTheOneThatShipsHasNoFile() throws {
        let folder = Folder()
        let store = ThemeStore(folder: folder.url)
        let file = folder.url.appending(path: "Standard.json")
        try store.update(Self.changedStandard(), for: "Standard")
        #expect(FileManager.default.fileExists(atPath: file.path))

        try store.update(.standard, for: "Standard")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(store.theme(named: "Standard")?.isCustomized == false)
        #expect(store.current == .standard)
        #expect(ThemeStore(folder: folder.url).theme(named: "Standard") == ThemeStore.builtInThemes[0])
    }

    @Test func resetPutsABuiltInThemeBackAsItShips() throws {
        let folder = Folder()
        let store = ThemeStore(folder: folder.url, selecting: "Ember")
        var changed = Theme.ember
        changed.panel.cornerRadius = 30
        try store.update(changed, for: "Ember")
        var seen: [ThemeStore.Changes] = []
        store.addObserver { seen.append($0) }

        try store.reset("ember")
        #expect(store.current == .ember)
        #expect(store.theme(named: "Ember") == ThemeStore.builtInThemes.first { $0.name == "Ember" })
        #expect(!FileManager.default.fileExists(atPath: folder.url.appending(path: "Ember.json").path))
        #expect(seen == [[.list, .current]])
        #expect(ThemeStore(folder: folder.url, selecting: "Ember").current == .ember)

        // Nothing to reset: no change is sent. A theme of the user's own has nothing to reset to.
        try store.reset("Ember")
        try store.save(.graphite, as: "Mine")
        try store.reset("Mine")
        #expect(store.theme(named: "Mine")?.theme == .graphite)
        #expect(FileManager.default.fileExists(atPath: folder.url.appending(path: "Mine.json").path))
        #expect(seen == [[.list, .current], .list])
        #expect(throws: ThemeStoreError.unknownTheme("Nope")) { try store.reset("Nope") }
    }

    @Test func updatingAUserThemeRewritesItsFile() throws {
        let folder = Folder()
        let store = ThemeStore(folder: folder.url)
        try store.save(.graphite, as: "Night")
        var seen: [ThemeStore.Changes] = []
        store.addObserver { seen.append($0) }

        try store.update(.ember, for: "night")
        #expect(seen == [.list])
        #expect(store.theme(named: "Night")?.theme == .ember)
        #expect(store.theme(named: "Night")?.isCustomized == false)
        #expect(ThemeStore(folder: folder.url).theme(named: "Night")?.theme == .ember)

        store.select("Night")
        var changed = Theme.ember
        changed.clarity = 0.2
        try store.update(changed, for: "Night")
        #expect(store.current == changed)
        #expect(seen.last == [.list, .current])
        #expect(ThemeStore(folder: folder.url, selecting: "Night").current == changed)
    }

    /// When the file cannot be written, the change still shows for this run, and the caller learns
    /// that it was not kept.
    @Test func aFolderThatCannotBeWrittenStillChangesTheThemeAndThrows() throws {
        let parent = Folder()
        try parent.write("not a folder", to: "Themes")
        let store = ThemeStore(folder: parent.url.appending(path: "Themes"))
        var seen: [ThemeStore.Changes] = []
        store.addObserver { seen.append($0) }
        let changed = Self.changedStandard()

        #expect(throws: (any Error).self) { try store.update(changed, for: "Standard") }
        #expect(store.current == changed)
        #expect(store.theme(named: "Standard")?.isCustomized == true)
        #expect(seen == [[.list, .current]])
    }

    /// The theme files in a folder, by name as the folder spells them.
    static func jsonFiles(in folder: Folder) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.url.path).filter { $0.hasSuffix(".json") }.sorted()
    }

    /// A file the user named in another case holds the changes, and it is the file an update writes
    /// and a reset removes. On a volume that tells case apart, writing `Standard.json` beside it
    /// would leave two files, and the older one would win at the next launch.
    @Test func aChangesFileSpelledInAnotherCaseIsTheOneUpdatedAndReset() throws {
        let folder = Folder()
        try folder.write(String(decoding: try JSONEncoder().encode(Theme.ember), as: UTF8.self), to: "standard.json")
        let store = ThemeStore(folder: folder.url)
        #expect(store.current == .ember)
        let changed = Self.changedStandard()

        try store.update(changed, for: "Standard")
        #expect(try Self.jsonFiles(in: folder) == ["standard.json"])
        #expect(ThemeStore(folder: folder.url).current == changed, "the next launch reads the latest change")

        try store.reset("Standard")
        #expect(try Self.jsonFiles(in: folder).isEmpty)
        #expect(ThemeStore(folder: folder.url).theme(named: "Standard") == ThemeStore.builtInThemes[0])
    }

    /// A file named after a built-in theme that does not decode, perhaps after a hand edit with a
    /// typo, stays as the user left it. The change still shows for this run, and the caller learns
    /// that it was not kept.
    @Test func aChangesFileThatCannotBeReadIsNeverWrittenOverOrRemoved() throws {
        let folder = Folder()
        let text = "{ \"clarity\": 1.2, oops"
        try folder.write(text, to: "Standard.json")
        let file = folder.url.appending(path: "Standard.json")
        let store = ThemeStore(folder: folder.url)
        #expect(store.problems.map(\.file.lastPathComponent) == ["Standard.json"])
        #expect(store.current == .standard)
        let changed = Self.changedStandard()
        func leftAlone(_ error: ThemeStoreError?) -> Bool {
            guard case .unreadable(let url, let reason) = error else { return false }
            return url.lastPathComponent == "Standard.json" && reason == "not JSON"
        }

        let edit = #expect(throws: ThemeStoreError.self) { try store.update(changed, for: "Standard") }
        #expect(leftAlone(edit))
        #expect(store.current == changed)
        #expect(try String(contentsOf: file, encoding: .utf8) == text)

        // Back as it ships, through an edit or a reset, removes nothing either.
        let back = #expect(throws: ThemeStoreError.self) { try store.update(.standard, for: "Standard") }
        #expect(leftAlone(back))
        let reset = #expect(throws: ThemeStoreError.self) { try store.reset("Standard") }
        #expect(leftAlone(reset))
        #expect(store.current == .standard)
        #expect(try String(contentsOf: file, encoding: .utf8) == text)
        #expect(ThemeStore(folder: folder.url).problems.map(\.file.lastPathComponent) == ["Standard.json"])

        // Once the user fixes the file, the store reads it and changes it as any other.
        try folder.write(String(decoding: try JSONEncoder().encode(Theme.ember), as: UTF8.self), to: "Standard.json")
        store.reload()
        #expect(store.problems.isEmpty && store.current == .ember)
        try store.update(changed, for: "Standard")
        #expect(ThemeStore(folder: folder.url).current == changed)
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
