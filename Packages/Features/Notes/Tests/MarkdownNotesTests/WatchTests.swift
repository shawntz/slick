import Foundation
import Kit
import KitTesting
import Testing

@testable import MarkdownNotes

@Suite("Watching the folder", .timeLimit(.minutes(1)))
struct WatchTests {
    @Test func aNoteEditedInAnotherAppShowsItsNewText() async throws {
        let harness = try await FeatureHarness.make([("Groceries.md", Sample.groceries)])
        try await harness.openSearch()
        let later = harness.fakes.clock.now.addingTimeInterval(60)
        try harness.write("Groceries.md", "# Groceries for Sunday\n\nApples\n", modified: later)
        try await harness.announceChange()
        #expect(harness.rows.map(\.title) == ["Groceries for Sunday"])
        try harness.select(title: "Groceries for Sunday")
        #expect(try await harness.loadDetail()?.body == .markdown("# Groceries for Sunday\n\nApples\n"))
        try await harness.setQuery("apples")
        #expect(harness.rows.map(\.title) == ["Groceries for Sunday"])
    }

    @Test func notesAddedAndRemovedElsewhereComeAndGo() async throws {
        let harness = try await FeatureHarness.make([("Groceries.md", Sample.groceries)])
        try await harness.openSearch()
        try harness.write("Budget 2027.md", Sample.budget)
        try FileManager.default.removeItem(at: harness.defaultFolder.appending(path: "Groceries.md"))
        try await harness.announceChange()
        #expect(harness.rows.map(\.title) == ["Budget 2027"])
    }

    @Test func changesBelowTheFolderReadNothing() async throws {
        let harness = try await FeatureHarness.make([("Groceries.md", Sample.groceries)])
        try harness.write("Budget 2027.md", Sample.budget)
        let deeper = harness.defaultFolder.appending(path: "Archive").appending(path: "old.md")
        try await harness.announceChange(in: deeper)
        #expect(harness.library.index.notes.map(\.title) == ["Groceries"])
        try await harness.announceChange(in: harness.defaultFolder.appending(path: "Budget 2027.md"))
        #expect(harness.library.index.notes.count == 2)
    }

    @Test func theFeaturesOwnSaveIsReadOnce() async throws {
        let harness = try await FeatureHarness.make([("Groceries.md", Sample.groceries)])
        try await harness.openSearch()
        _ = try await harness.library.create("# Fresh\n")
        let generation = harness.library.changes.generation
        // The watcher reports the save; nothing changed since, so nothing reloads.
        try await harness.announceChange()
        #expect(harness.library.changes.generation == generation)
        #expect(harness.rows.map(\.title) == ["Fresh", "Groceries"])
    }

    @Test func openingTheListReadsTheFolderAgain() async throws {
        let harness = try await FeatureHarness.make([("Groceries.md", Sample.groceries)])
        // A change no event reported, as after a dropped event.
        try harness.write("Budget 2027.md", Sample.budget)
        try await harness.openSearch()
        #expect(Set(harness.rows.map(\.title)) == ["Groceries", "Budget 2027"])
    }

    @Test func switchingTheFeatureOffAndOnKeepsOneWatch() async throws {
        let harness = try await FeatureHarness.make([("Groceries.md", Sample.groceries)])
        #expect(harness.fakes.fileWatcher.watchedDirectories.count == 1)
        for _ in 0..<3 {
            await harness.deactivate()
            #expect(harness.fakes.fileWatcher.watchedDirectories.isEmpty)
            try await harness.start()
        }
        #expect(harness.fakes.fileWatcher.watchedDirectories.map(\.lastPathComponent) == [NoteFolder.defaultName])
        // A note written while the feature was off shows after it is on again.
        await harness.deactivate()
        try harness.write("Budget 2027.md", Sample.budget)
        try await harness.start()
        #expect(harness.library.index.notes.count == 2)
    }

    @Test func activationAsksForNothingAndReadsOnlyItsOwnFolder() async throws {
        let fakes = FakeServices()
        let recording = RecordingDisk(base: NoteDiskKey.isolated(fakes.context(featureID: NoteIDs.feature)))
        fakes.override(NoteDiskKey.self, with: recording)
        let harness = try await FeatureHarness.make([("Groceries.md", Sample.groceries)], fakes: fakes)
        #expect(recording.listedFolders == [NoteFolder.defaultName])
        #expect(recording.readNames == ["Groceries.md"])
        #expect(fakes.permissions.openStreamCount == 0)
        #expect(fakes.permissions.requests.isEmpty)
        #expect(fakes.http.requests.isEmpty)
        #expect(fakes.pasteboard.copied.isEmpty)
        // A second scan reads nothing that did not change.
        await harness.library.rescan()
        #expect(recording.readNames == ["Groceries.md"])
    }
}
