import Foundation
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import Observation
import SwiftUI
import Synchronization
import Testing

@testable import SettingsUI

@MainActor @Suite(.timeLimit(.minutes(1))) struct AppearanceModelTests {
    @Test func listsBuiltInThemesAndSelectsOne() {
        let bed = TestBed()
        let model = AppearanceModel(context: bed.context())
        #expect(model.themes.map(\.name) == ThemeStore.builtInThemes.map(\.name))
        #expect(Array(model.themes.map(\.name).prefix(4)) == ["Standard", "Graphite", "Ocean", "Ember"])
        #expect(model.selectedName == "Standard")
        #expect(model.isBuiltIn)
        model.select("Ocean")
        #expect(bed.themes.selectedName == "Ocean")
        #expect(bed.general[HostSettings.themeName] == "Ocean")
        #expect(model.draft == Theme.ocean)
        #expect(!model.isCustomized)
    }

    @Test func theEditorPicksTheGlassStyleAndTheArrangement() throws {
        let bed = TestBed()
        let model = AppearanceModel(context: bed.context())
        #expect(model.glassStyle == .regular && model.layout == .single)
        model.glassStyle = .clear
        model.layout = .split
        #expect(model.draft.panel.glassStyle == .clear && model.draft.panel.layout == .split)
        #expect(model.isCustomized)
        model.select("Spotlight")
        let standard = try #require(bed.themes.theme(named: "Standard")?.theme)
        #expect(standard.panel.glassStyle == .clear && standard.panel.layout == .split, "Standard kept the change")
        #expect(model.layout == .split && model.glassStyle == .regular)
        #expect(!model.summary.isEmpty)
        model.select("Glass")
        #expect(model.glassStyle == .clear && model.layout == .single)
        // Glass's sentence warns that its text is harder to read, so the user reads it before choosing.
        #expect(model.summary.contains("harder to read"))
    }

    /// The preview draws the draft at once. The launcher gets it when the edits pause or the pane
    /// commits them.
    @Test func editsChangeTheDraftAtOnceAndTheStoreOnFlush() throws {
        let bed = TestBed()
        let model = AppearanceModel(context: bed.context())
        model.commitDelay = .seconds(60)
        model.clarity = 1.4
        model.lensStyle = .fill
        model.titleSize = 16
        model.subtitleSize = 12
        model.querySize = 26
        model.rowHeight = 50
        model.cornerRadius = 20
        model.lensCornerRadius = 8
        model.setTintStrength(0.4, dark: true)
        model.setGlassTintColor(red: 0.1, green: 0.2, blue: 0.3, dark: false)
        #expect(model.isCustomized)
        #expect(bed.themes.current == Theme.standard, "the edit waits for the edits to pause")
        let draft = model.draft
        #expect(draft.clarity == 1.4)
        #expect(draft.lens.style == .fill)
        #expect(draft.fonts.title.size == 16)
        // Related sizes follow by the same change.
        #expect(draft.fonts.cardRow.size == Theme.standard.fonts.cardRow.size + 1.5)
        #expect(draft.fonts.subtitle.size == 12)
        #expect(draft.fonts.query.size == 26)
        #expect(draft.list.rowHeight == 50)
        #expect(
            draft.list.twoLineRowHeight == 50 + Theme.standard.list.twoLineRowHeight - Theme.standard.list.rowHeight)
        #expect(draft.panel.cornerRadius == 20)
        #expect(draft.lens.cornerRadius == 8)
        #expect(draft.dark.glassTint.alpha == 0.4)
        #expect(
            draft.light.glassTint
                == ThemeColor(red: 0.1, green: 0.2, blue: 0.3, alpha: Theme.standard.light.glassTint.alpha))

        model.flush()
        #expect(bed.themes.current == draft)
        #expect(bed.themes.selectedName == "Standard")
        #expect(bed.themes.theme(named: "Standard")?.isCustomized == true)
        #expect(FileManager.default.fileExists(atPath: bed.themes.folder.appending(path: "Standard.json").path))
        #expect(model.draft == draft)
    }

    @Test func keepsEditsInRange() {
        let bed = TestBed()
        let model = AppearanceModel(context: bed.context())
        model.clarity = 9
        model.rowHeight = 4
        model.setTintStrength(5, dark: false)
        #expect(model.clarity == AppearanceModel.Limits.clarity.upperBound)
        #expect(model.rowHeight == AppearanceModel.Limits.rowHeight.lowerBound)
        #expect(model.tintStrength(dark: false) == AppearanceModel.Limits.tintStrength.upperBound)
    }

    @Test func accentReplacesEverySystemAccentColour() {
        let bed = TestBed()
        let model = AppearanceModel(context: bed.context())
        #expect(model.followsSystemAccent)
        let teal = ThemeColor(red: 0.0, green: 0.5, blue: 0.5)
        model.accent = teal
        #expect(!model.followsSystemAccent)
        #expect(model.accent == teal)
        let light = model.draft.light
        #expect(light.prominent == teal)
        #expect(light.link == teal)
        #expect(light.focusRing == teal.scaled(by: Theme.standard.light.focusRing.alpha))
        #expect(light.lensGlassTint == teal.scaled(by: Theme.standard.light.lensGlassTint.alpha))
        #expect(model.draft.dark.loadingBar == teal)
        model.followsSystemAccent = true
        #expect(model.draft.light.prominent == Theme.standard.light.prominent)
        #expect(model.draft == Theme.standard)
    }

    /// Save as New Theme copies the theme as it is, changes included, and selects the copy. The
    /// built-in theme keeps the changes too.
    @Test func saveAsNewThemeCopiesTheChangedThemeAndSelectsTheCopy() throws {
        let bed = TestBed()
        let context = bed.context()
        let model = AppearanceModel(context: context)
        model.clarity = 1.5
        #expect(model.suggestedNewName == "Standard Copy")
        #expect(model.saveAsNew(named: "Mine"))
        #expect(bed.themes.selectedName == "Mine")
        #expect(bed.general[HostSettings.themeName] == "Mine")
        #expect(bed.themes.current.clarity == 1.5)
        #expect(model.draft.clarity == 1.5)
        #expect(!model.isBuiltIn && !model.isCustomized)
        #expect(bed.themes.theme(named: "Standard")?.theme.clarity == 1.5)
        #expect(bed.themes.themes.map(\.name) == ThemeStore.builtInThemes.map(\.name) + ["Mine"])
        #expect(FileManager.default.fileExists(atPath: bed.themes.folder.appending(path: "Mine.json").path))
        #expect(model.suggestedNewName == "Mine Copy")
    }

    @Test func savingUnderABuiltInNameFails() {
        let bed = TestBed()
        let context = bed.context()
        let model = AppearanceModel(context: context)
        #expect(!model.saveAsNew(named: "ocean"))
        #expect(context.toasts.current?.toast.style == .failure)
        #expect(bed.themes.selectedName == "Standard")
    }

    @Test func anEditToAUserThemeRewritesItsFile() throws {
        let bed = TestBed()
        try bed.themes.save(.graphite, as: "Night")
        let model = AppearanceModel(context: bed.context())
        model.select("Night")
        model.cornerRadius = 30
        model.flush()
        #expect(!model.isCustomized, "only a built-in theme counts as changed")
        #expect(bed.themes.current.panel.cornerRadius == 30)
        let reread = ThemeStore(folder: bed.themes.folder, selecting: "Night")
        #expect(reread.current.panel.cornerRadius == 30)
    }

    @Test func deletesAUserThemeAfterConfirming() async throws {
        let bed = TestBed()
        try bed.themes.save(.ember, as: "Warm")
        let context = bed.context()
        let model = AppearanceModel(context: context)
        model.select("Warm")
        let task = Task { await model.delete("Warm") }
        #expect(await eventually { context.confirmations.pending != nil })
        #expect(context.confirmations.pending?.confirmation.isDestructive == true)
        context.confirmations.answer(true)
        await task.value
        #expect(bed.themes.theme(named: "Warm") == nil)
        #expect(model.selectedName == "Standard")
        #expect(bed.general[HostSettings.themeName] == "Standard")
    }

    @Test func importsAndExportsThemeFiles() async throws {
        let bed = TestBed()
        let context = bed.context()
        let model = AppearanceModel(context: context)
        let outside = bed.root.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        bed.fakes.fileDialogs.saveLocation = outside.appending(path: "Shared.json")
        model.select("Ember")
        await model.exportTheme()
        #expect(bed.fakes.fileDialogs.saveRequests.first?.suggestedName == "Ember.json")
        bed.fakes.fileDialogs.filesToChoose = [outside.appending(path: "Shared.json")]
        await model.importTheme()
        #expect(model.selectedName == "Shared")
        #expect(bed.themes.current == Theme.ember)

        // An edited theme exports with its edits.
        model.clarity = 0.5
        bed.fakes.fileDialogs.saveLocation = outside.appending(path: "Edited.json")
        await model.exportTheme()
        let data = try Data(contentsOf: outside.appending(path: "Edited.json"))
        #expect(try JSONDecoder().decode(Theme.self, from: data).clarity == 0.5)
    }

    @Test func listsSkippedFiles() throws {
        let bed = TestBed()
        try FileManager.default.createDirectory(at: bed.themes.folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bed.themes.folder.appending(path: "Broken.json"))
        let model = AppearanceModel(context: bed.context())
        model.reload()
        #expect(model.problems.map(\.file.lastPathComponent) == ["Broken.json"])
    }

    /// A selection made elsewhere, as in onboarding, replaces the draft, and the edit that waited
    /// is dropped, so it never lands on either theme.
    @Test func aSelectionMadeElsewhereReplacesTheDraft() async throws {
        let bed = TestBed()
        let model = AppearanceModel(context: bed.context())
        model.commitDelay = .milliseconds(20)
        bed.themes.select("Graphite")
        #expect(model.draft == Theme.graphite)
        model.clarity = 0.3
        bed.themes.select("Ocean")
        #expect(model.draft == Theme.ocean)
        try await Task.sleep(for: .milliseconds(150))
        model.flush()
        #expect(bed.themes.theme(named: "Graphite")?.theme == Theme.graphite)
        #expect(bed.themes.current == Theme.ocean)
        #expect(!FileManager.default.fileExists(atPath: bed.themes.folder.path))
    }

    // MARK: Edits reach the launcher

    @Test func anEditReachesTheStoreByItselfAfterAMoment() async throws {
        let bed = TestBed()
        let model = AppearanceModel(context: bed.context())
        model.clarity = 1.3
        model.rowHeight = 48
        #expect(await eventually { bed.themes.current.clarity == 1.3 }, "the launcher gets the edit")
        #expect(bed.themes.current.list.rowHeight == 48)
        #expect(FileManager.default.fileExists(atPath: bed.themes.folder.appending(path: "Standard.json").path))
    }

    @Test func aBuiltInThemesEditSurvivesANewStore() async throws {
        let bed = TestBed()
        let model = AppearanceModel(context: bed.context())
        model.select("Ember")
        model.cornerRadius = 28
        model.followsSystemAccent = true
        #expect(await eventually { bed.themes.current.panel.cornerRadius == 28 })

        let next = ThemeStore(folder: bed.themes.folder, selecting: bed.general[HostSettings.themeName])
        #expect(next.selectedName == "Ember")
        #expect(next.current.panel.cornerRadius == 28)
        #expect(next.current.accent == nil)
        #expect(next.problems.isEmpty)
        #expect(next.themes.map(\.name) == ThemeStore.builtInThemes.map(\.name))
    }

    @Test func selectingAnotherThemeFirstCommitsWhatWaitsToTheOldOne() {
        let bed = TestBed()
        let model = AppearanceModel(context: bed.context())
        model.commitDelay = .seconds(60)
        model.clarity = 0.6
        model.select("Ocean")
        #expect(bed.themes.theme(named: "Standard")?.theme.clarity == 0.6)
        #expect(bed.themes.theme(named: "Ocean")?.theme == Theme.ocean)
        #expect(model.draft == Theme.ocean)
        #expect(bed.themes.current == Theme.ocean)
    }

    @Test func resetBringsBackTheShippedThemeAfterConfirming() async throws {
        let bed = TestBed()
        let context = bed.context()
        let model = AppearanceModel(context: context)
        // Only the reset's own flush can bring the edit to the store before the question.
        model.commitDelay = .seconds(60)
        let shipped = try #require(ThemeStore.builtInThemes.first)
        #expect(model.summary == shipped.summary)
        #expect(!model.isCustomized)
        model.titleSize = 17
        #expect(model.isCustomized)
        #expect(model.summary == "You changed Standard. Reset to Default undoes your changes.")

        // Declining keeps the change.
        let declined = Task { await model.resetToDefault() }
        #expect(await eventually { context.confirmations.pending != nil })
        context.confirmations.answer(false)
        await declined.value
        #expect(bed.themes.current.titleSize == 17, "asking first committed the change")
        #expect(model.isCustomized)

        let reset = Task { await model.resetToDefault() }
        #expect(await eventually { context.confirmations.pending != nil })
        let question = try #require(context.confirmations.pending?.confirmation)
        #expect(question.title == "Reset Standard?")
        #expect(question.message == "Your changes to Standard are removed. This cannot be undone.")
        #expect(question.confirmTitle == "Reset")
        #expect(question.isDestructive)
        context.confirmations.answer(true)
        await reset.value

        #expect(bed.themes.current == Theme.standard)
        #expect(model.draft == Theme.standard)
        #expect(!model.isCustomized)
        #expect(model.summary == shipped.summary)
        #expect(!FileManager.default.fileExists(atPath: bed.themes.folder.appending(path: "Standard.json").path))
    }

    @Test func aThemeOfTheUsersOwnHasNothingToReset() async throws {
        let bed = TestBed()
        try bed.themes.save(.graphite, as: "Night")
        let context = bed.context()
        let model = AppearanceModel(context: context)
        model.select("Night")
        model.clarity = 0.2
        await model.resetToDefault()
        #expect(context.confirmations.pending == nil)
        #expect(bed.themes.current.clarity == 0.2)
        #expect(model.summary.isEmpty)
    }

    /// When the file cannot be written, the launcher still shows the change for this run, one
    /// failure toast says it was not kept, and the draft stays.
    @Test func aThemeThatCannotBeSavedShowsOneToastAndKeepsTheDraft() throws {
        let bed = TestBed()
        try FileManager.default.createDirectory(at: bed.root, withIntermediateDirectories: true)
        try Data("not a folder".utf8).write(to: bed.themes.folder)
        let context = bed.context()
        let model = AppearanceModel(context: context)
        model.clarity = 1.2
        model.flush()
        let toast = try #require(context.toasts.current)
        #expect(toast.toast.style == .failure)
        #expect(toast.toast.title == "Could not save the theme")
        #expect(model.draft.clarity == 1.2)
        #expect(bed.themes.current.clarity == 1.2)

        model.flush()
        #expect(context.toasts.current?.id == toast.id, "a second flush has nothing new to commit")
        model.clarity = 1.4
        model.flush()
        #expect(context.toasts.current?.id != toast.id, "a new failure shows again")
        #expect(context.toasts.current?.toast.style == .failure)
    }

    // MARK: Appearance

    @Test func theAppearanceControlWritesTheSettingAndFollowsAChangeElsewhere() async {
        let bed = TestBed()
        let model = AppearanceModel(context: bed.context())
        #expect(model.appearance == .system)
        #expect(model.previewDark == nil)

        model.appearance = .dark
        #expect(bed.general[HostSettings.appearance] == .dark)
        #expect(model.previewDark == true)

        bed.general[HostSettings.appearance] = .light
        #expect(await eventually { model.appearance == .light })
        #expect(model.previewDark == false)
        model.appearance = .system
        #expect(bed.general[HostSettings.appearance] == .system)
        #expect(model.previewDark == nil)
    }

    /// The Appearance row draws again when the setting changes elsewhere, as through Reset All
    /// Settings: the model tells observation, besides answering with the new value when asked.
    @Test func theAppearanceRowRedrawsWhenTheSettingChangesElsewhere() async {
        let bed = TestBed()
        let model = AppearanceModel(context: bed.context())
        let changed = Signal()
        withObservationTracking {
            _ = model.appearance
        } onChange: {
            changed.set()
        }
        bed.general[HostSettings.appearance] = .dark
        #expect(await eventually { changed.value })
    }

    // MARK: When edits reach the launcher

    /// A drag that moves a slider faster than the delay restyles the launcher and writes the file
    /// once, after it pauses, not on every tick.
    @Test func aDragRestylesTheLauncherOnceItPauses() async {
        let bed = TestBed()
        let model = AppearanceModel(context: bed.context())
        let clock = FakeClock()
        model.clock = clock
        var restyles = 0
        let observer = bed.themes.addObserver { if $0.contains(.current) { restyles += 1 } }
        defer { bed.themes.removeObserver(observer) }

        // Ticks a third of the delay apart, for four times the delay.
        for step in 0..<12 {
            model.clarity = 0.5 + Double(step) * 0.05
            await clock.waitForSleepers()
            clock.advance(by: model.commitDelay / 3)
            for _ in 0..<10 { await Task.yield() }
        }
        #expect(restyles == 0, "nothing reaches the launcher while the drag goes on")
        #expect(bed.themes.current == Theme.standard)

        clock.advance(by: model.commitDelay)
        #expect(await eventually { restyles == 1 })
        #expect(bed.themes.current.clarity == model.draft.clarity)
        #expect(clock.sleeperCount == 0)
    }

    /// Going to another pane commits the edit that waits, at once.
    @Test func leavingThePaneCommitsWhatWaits() {
        let bed = TestBed()
        let model = AppearanceModel(context: bed.context())
        let gate = PaneGate()
        let size = CGSize(width: 760, height: 1480)
        let window = OffscreenWindow(
            PaneOrAnother(gate: gate, model: model).frame(width: 760, height: 1480), size: size)
        defer { window.close() }
        model.commitDelay = .seconds(60)
        model.cornerRadius = 30
        #expect(bed.themes.current.panel.cornerRadius == Theme.standard.panel.cornerRadius)

        gate.showsPane = false
        for _ in 0..<10 where bed.themes.current.panel.cornerRadius != 30 { window.settle() }
        #expect(bed.themes.current.panel.cornerRadius == 30)
    }

    // MARK: Themes are never lost

    /// Save as New Theme never replaces a theme. A name one of the user's themes has is refused,
    /// as a built-in theme's name is, and the theme keeps its values and its file.
    @Test func saveAsNewThemeNeverReplacesATheme() throws {
        let bed = TestBed()
        try bed.themes.save(.graphite, as: "Mine")
        let context = bed.context()
        let model = AppearanceModel(context: context)
        model.clarity = 1.5

        #expect(!model.saveAsNew(named: " mine "))
        #expect(context.toasts.current?.toast.style == .failure)
        #expect(
            context.toasts.current?.toast.title == "You already have a theme named Mine. Save it under another name.")
        #expect(bed.themes.theme(named: "Mine")?.theme == .graphite)
        #expect(ThemeStore(folder: bed.themes.folder).theme(named: "Mine")?.theme == .graphite)
        #expect(bed.themes.selectedName == "Standard")

        #expect(!model.saveAsNew(named: "Ocean"))
        #expect(context.toasts.current?.toast.title == "Ocean is a built-in theme. Save it under another name.")
        #expect(bed.themes.theme(named: "Ocean")?.theme == .ocean)
        #expect(bed.themes.themes.map(\.name) == ThemeStore.builtInThemes.map(\.name) + ["Mine"])
    }

    /// A theme file the store could not read stays as the user left it. An edit to that theme
    /// shows for this run, and the failure toast names the file.
    @Test func anEditLeavesAThemeFileThatCannotBeReadAlone() throws {
        let bed = TestBed()
        let file = bed.themes.folder.appending(path: "Standard.json")
        try FileManager.default.createDirectory(at: bed.themes.folder, withIntermediateDirectories: true)
        try Data("{ oops".utf8).write(to: file)
        bed.themes.reload()
        let context = bed.context()
        let model = AppearanceModel(context: context)
        #expect(model.problems.map(\.file.lastPathComponent) == ["Standard.json"])

        model.cornerRadius = 30
        model.flush()
        let toast = try #require(context.toasts.current?.toast)
        #expect(toast.style == .failure)
        #expect(toast.title == "Could not save the theme")
        #expect(toast.message == "Standard.json is not a theme: not JSON.")
        #expect(try String(contentsOf: file, encoding: .utf8) == "{ oops")
        #expect(bed.themes.current.panel.cornerRadius == 30)
    }
}

/// Set once observation reports a change, from whatever thread reports it.
nonisolated private final class Signal: Sendable {
    private let fired = Mutex(false)
    var value: Bool { fired.withLock { $0 } }
    func set() { fired.withLock { $0 = true } }
}

/// Shows the Appearance pane, or another view in its place, as the settings window does when the
/// person picks another pane.
@Observable private final class PaneGate {
    var showsPane = true
}

private struct PaneOrAnother: View {
    let gate: PaneGate
    let model: AppearanceModel

    var body: some View {
        if gate.showsPane { AppearancePane(model: model) } else { Text("Another pane") }
    }
}
