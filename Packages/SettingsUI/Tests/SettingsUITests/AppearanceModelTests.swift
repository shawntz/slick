import Foundation
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
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
        #expect(!model.isEdited)
    }

    @Test func theEditorPicksTheGlassStyleAndTheArrangement() {
        let bed = TestBed()
        let model = AppearanceModel(context: bed.context())
        #expect(model.glassStyle == .regular && model.layout == .single)
        model.glassStyle = .clear
        model.layout = .split
        #expect(model.draft.panel.glassStyle == .clear && model.draft.panel.layout == .split)
        #expect(model.isEdited && bed.themes.current == Theme.standard)
        model.select("Beam")
        #expect(model.layout == .split && model.glassStyle == .regular)
        #expect(!model.summary.isEmpty)
        model.select("Clear")
        #expect(model.glassStyle == .clear && model.layout == .single)
        // Clear's sentence says where its text falls short, so the user reads it before choosing.
        #expect(model.summary.contains("4.5"))
    }

    @Test func editsChangeTheDraftOnly() {
        let bed = TestBed()
        let model = AppearanceModel(context: bed.context())
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
        #expect(model.isEdited)
        #expect(bed.themes.current == Theme.standard)
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
        model.revert()
        #expect(!model.isEdited)
        #expect(model.draft == Theme.standard)
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

    @Test func builtInThemesAreSavedUnderANewName() throws {
        let bed = TestBed()
        let context = bed.context()
        let model = AppearanceModel(context: context)
        model.clarity = 1.5
        model.save()
        #expect(bed.themes.themes.count == ThemeStore.builtInThemes.count, "a built-in theme is not overwritten")
        #expect(model.suggestedNewName == "Standard Copy")
        #expect(model.saveAsNew(named: "Mine"))
        #expect(bed.themes.selectedName == "Mine")
        #expect(bed.general[HostSettings.themeName] == "Mine")
        #expect(bed.themes.current.clarity == 1.5)
        #expect(!model.isEdited)
        #expect(!model.isBuiltIn)
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

    @Test func savesOverAUserTheme() throws {
        let bed = TestBed()
        try bed.themes.save(.graphite, as: "Night")
        let model = AppearanceModel(context: bed.context())
        model.select("Night")
        model.cornerRadius = 30
        model.save()
        #expect(!model.isEdited)
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

    @Test func followsASelectionMadeElsewhereWhenNotEditing() {
        let bed = TestBed()
        let model = AppearanceModel(context: bed.context())
        bed.themes.select("Graphite")
        #expect(model.draft == Theme.graphite)
        model.clarity = 0.3
        bed.themes.select("Ocean")
        #expect(model.draft.clarity == 0.3)
    }
}
