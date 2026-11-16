import Foundation
import Kit
import KitTesting
import Testing

@testable import MarkdownNotes

@Suite("Root search and settings", .timeLimit(.minutes(1)))
struct RootTests {
    @Test func noteTitlesJoinRootSearchOnlyWhenTheSettingIsOn() async throws {
        let harness = try await FeatureHarness.make([
            ("Groceries.md", Sample.groceries), ("Budget 2027.md", Sample.budget),
        ])
        #expect(harness.context.settings[NotesSettings.showsInRootSearch] == false)
        #expect(try await harness.catalogRows().isEmpty)
        #expect(harness.feature.catalogSources.first?.reloadsOnSettings == [NotesSettings.showsInRootSearch.erased])

        harness.context.settings[NotesSettings.showsInRootSearch] = true
        try await harness.library.setPinned(true, fileName: "Budget 2027.md")
        let rows = try await harness.catalogRows()
        #expect(rows.map(\.title) == ["Budget 2027", "Groceries"])
        #expect(rows.allSatisfy { $0.memory == .learnOnly })
        #expect(rows.last?.keywords == ["#errands"])
        #expect(rows.first?.represents == .files([harness.defaultFolder.appending(path: "Budget 2027.md")]))
    }

    @Test func aRootRowWorksFromItsIDAloneAndShowsTheNote() async throws {
        let harness = try await FeatureHarness.make([("Groceries.md", Sample.groceries)])
        // As root search hands back a row rebuilt from a snapshot after a relaunch.
        let row = Row(id: NoteIDs.row("Groceries.md"), title: "Groceries")
        let actions = harness.rootActions(for: row)
        #expect(actions.first?.id == "show")
        #expect(actions.secondary?.id == "open")
        try await harness.performRoot("show", on: row)
        #expect(harness.detail?.body == .markdown(Sample.groceries))
        #expect(harness.actions().first?.id == "edit")

        // Deleting from the note's own page goes back.
        let outcome = try await harness.perform("move-to-trash")
        #expect(outcome.kind == .pop)
        #expect(harness.issues.isEmpty)
        #expect(harness.pendingIssues.isEmpty)
    }

    @Test func theSettingsPaneSaysWhereNotesLiveAndHowToCapture() async throws {
        let harness = try await FeatureHarness.make()
        let pane = try #require(harness.feature.settingsPane)
        #expect(pane.sections.map(\.title) == ["Root Search", "Notes Folder", "Quick Capture"])
        let items = pane.sections.flatMap(\.items).map(\.title)
        #expect(
            items == [
                "Show note titles in root search", Strings.defaultFolderNote, "Choose Folder…", "Use Default Folder",
                "Show in Finder", "Save notes from root search",
            ])
        try await harness.pressSettingsButton("Show in Finder")
        #expect(harness.fakes.workspace.revealed == [harness.defaultFolder])
        #expect(harness.feature.status == nil)
    }

    @Test func aDamagedPinsFileIsKeptAndPinsCannotChange() async throws {
        let fakes = FakeServices()
        let pins = fakes.context(featureID: NoteIDs.feature).storage.dataFile("pins.json")
        try FileManager.default.createDirectory(at: pins.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ \"version\": 1, \"folders\": [".utf8).write(to: pins)
        let harness = try await FeatureHarness.make([("Groceries.md", Sample.groceries)], fakes: fakes)
        #expect(harness.feature.status?.title == "Pins Could Not Be Read")
        await #expect(throws: ActionFailure.self) {
            try await harness.library.setPinned(true, fileName: "Groceries.md")
        }
        #expect(try String(contentsOf: pins, encoding: .utf8) == "{ \"version\": 1, \"folders\": [")
    }

    @Test func pinsFromANewerVersionShowButAreNeverSavedOver() async throws {
        let fakes = FakeServices()
        let pins = fakes.context(featureID: NoteIDs.feature).storage.dataFile("pins.json")
        try FileManager.default.createDirectory(at: pins.deletingLastPathComponent(), withIntermediateDirectories: true)
        let newer = "{\"version\": 2, \"folders\": {\"default\": [\"Groceries.md\"]}, \"colors\": {}}"
        try Data(newer.utf8).write(to: pins)
        let harness = try await FeatureHarness.make([("Groceries.md", Sample.groceries)], fakes: fakes)
        #expect(harness.library.pinned == ["Groceries.md"])
        #expect(harness.feature.status?.title == "Pins Are Read Only")
        await #expect(throws: ActionFailure.self) {
            try await harness.library.setPinned(false, fileName: "Groceries.md")
        }
        #expect(try String(contentsOf: pins, encoding: .utf8) == newer)
    }
}
