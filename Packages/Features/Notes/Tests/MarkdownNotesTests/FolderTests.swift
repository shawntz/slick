import Darwin
import Foundation
import Kit
import KitTesting
import Testing

@testable import MarkdownNotes

@Suite("The notes folder", .timeLimit(.minutes(1)))
struct FolderTests {
    @Test func theDefaultFolderIsInTheFeaturesDataFolder() async throws {
        let harness = try await FeatureHarness.make()
        #expect(harness.defaultFolder.path == harness.context.storage.dataDirectory.appending(path: "Notes").path)
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: harness.defaultFolder.path, isDirectory: &isFolder))
        #expect(isFolder.boolValue)
        #expect(harness.library.index.folder.isDefault)
    }

    @Test func theDefaultFolderComesBackWhenSomeoneDeletesIt() async throws {
        let harness = try await FeatureHarness.make([("Groceries.md", Sample.groceries)])
        try FileManager.default.removeItem(at: harness.defaultFolder)
        try await harness.announceChange()
        #expect(harness.library.index.notes.isEmpty)
        #expect(harness.library.index.problem == nil)
        let row = try #require(harness.instantAnswers(for: "note still works").first?.rows.first)
        try await harness.performRoot("save", on: row)
        #expect(try harness.names() == ["still works.md"])
    }

    @Test func choosingAFolderReadsItAtOnceAndLeavesTheOldNotesWhereTheyAre() async throws {
        let harness = try await FeatureHarness.make([("Groceries.md", Sample.groceries)])
        let writing = harness.home.appending(path: "Writing")
        try harness.write("Budget 2027.md", Sample.budget, in: writing)
        harness.fakes.fileDialogs.filesToChoose = [writing]
        try await harness.pressSettingsButton("Choose Folder…")
        #expect(harness.fakes.fileDialogs.openRequests.last?.canChooseDirectories == true)
        #expect(harness.fakes.fileDialogs.openRequests.last?.canChooseFiles == false, "the dialog offers folders only")
        #expect(harness.toasts.last?.title == "Notes Folder Changed")
        #expect(harness.context.settings[NotesSettings.folder] == writing.path)
        #expect(harness.library.index.notes.map(\.title) == ["Budget 2027"])
        #expect(harness.fakes.fileWatcher.watchedDirectories.map(\.lastPathComponent) == ["Writing"])
        // Notes in the old folder stay there.
        #expect(try harness.names() == ["Groceries.md"])
        #expect(harness.feature.settingsPane?.sections[1].items.first?.title == Strings.folderNote(writing.path))

        // New notes go to the chosen folder.
        _ = try await harness.library.create("# Ideas\n")
        #expect(try harness.names(in: writing) == ["Budget 2027.md", "Ideas.md"])

        try await harness.pressSettingsButton("Use Default Folder")
        #expect(harness.library.index.notes.map(\.title) == ["Groceries"])
        #expect(harness.context.settings[NotesSettings.folder] == "")
    }

    @Test func aGuardedFolderIsFirstReadRightAfterTheUserChoseIt() async throws {
        let fakes = FakeServices()
        let recording = RecordingDisk(base: NoteDiskKey.isolated(fakes.context(featureID: NoteIDs.feature)))
        fakes.override(NoteDiskKey.self, with: recording)
        let harness = try await FeatureHarness.make(fakes: fakes)
        let documents = harness.home.appending(path: "Documents").appending(path: "Journal")
        try harness.write("Plans.md", "# Plans\n", in: documents)
        // Before the choice, only the default folder was ever listed.
        #expect(recording.listedFolders == [NoteFolder.defaultName])

        fakes.fileDialogs.filesToChoose = [documents]
        try await harness.pressSettingsButton("Choose Folder…")
        // The read happened inside the button's run, the moment after the choice.
        #expect(recording.listedFolders.last == "Journal")
        #expect(harness.library.index.folder.guarded == .documents)
        #expect(harness.library.index.notes.map(\.title) == ["Plans"])
        #expect(harness.context.settings[NotesSettings.confirmedFolder] == documents.path)

        // The next launch reads it at once: it was read after the user chose it.
        await harness.deactivate()
        let relaunched = try await FeatureHarness.make(fakes: fakes)
        #expect(relaunched.library.index.notes.map(\.title) == ["Plans"])
    }

    @Test func aGuardedFolderNeverReadSinceTheChoiceWaitsForTheUser() async throws {
        let fakes = FakeServices()
        let recording = RecordingDisk(base: NoteDiskKey.isolated(fakes.context(featureID: NoteIDs.feature)))
        fakes.override(NoteDiskKey.self, with: recording)
        let home = fakes.storage.homeDirectory
        let desktop = home.appending(path: "Desktop").appending(path: "Jots")
        // A folder named in settings, such as one whose first read macOS refused, or one set by hand.
        fakes.context(featureID: NoteIDs.feature).settings[NotesSettings.folder] = desktop.path
        let harness = FeatureHarness(fakes: fakes) { NotesFeature(context: $0) }
        try harness.write("Plans.md", "# Plans\n", in: desktop)
        try await harness.start()

        #expect(recording.listedFolders.isEmpty)
        #expect(recording.readNames.isEmpty)
        #expect(fakes.fileWatcher.watchedDirectories.isEmpty)
        #expect(harness.feature.status?.title == "Notes Folder Not Read Yet")
        try await harness.openSearch()
        #expect(harness.rows.isEmpty)
        #expect(recording.listedFolders.isEmpty)
        let notice = try #require(harness.page?.notice)
        #expect(notice.title == "Notes Folder Not Read Yet")
        #expect(notice.action?.id == "read-folder")
        #expect(harness.page?.emptyState?.actions.map(\.id) == ["use-default-folder"])
        // Writing waits too.
        await #expect(throws: ActionFailure.self) { _ = try await harness.library.create("# New\n") }
        #expect(try harness.names(in: desktop) == ["Plans.md"])

        try await harness.perform(try #require(notice.action), row: nil)
        #expect(recording.listedFolders == ["Jots"])
        #expect(harness.rows.map(\.title) == ["Plans"])
        #expect(harness.page?.notice == nil)
        #expect(harness.context.settings[NotesSettings.confirmedFolder] == desktop.path)
    }

    @Test func aFolderThatRefusesShowsWhyAndTheWayBack() async throws {
        let harness = try await FeatureHarness.make([("Groceries.md", Sample.groceries)])
        let locked = harness.home.appending(path: "Documents").appending(path: "Locked")
        try harness.write("Secret plans.md", "# Secret plans\n", in: locked)
        #expect(chmod(locked.path, 0o000) == 0)
        defer { chmod(locked.path, 0o755) }

        harness.fakes.fileDialogs.filesToChoose = [locked]
        try await harness.pressSettingsButton("Choose Folder…")
        #expect(harness.toasts.last?.title == "Notes Folder Cannot Be Read")
        #expect(harness.feature.status?.title == "Notes Folder Cannot Be Read")
        #expect(harness.context.settings[NotesSettings.confirmedFolder] == "")

        try await harness.openSearch()
        #expect(harness.rows.isEmpty)
        let notice = try #require(harness.page?.notice)
        #expect(notice.title == "Notes Folder Cannot Be Read")
        #expect(notice.message?.contains("refused access to “Locked”") == true)
        #expect(notice.action?.id == "use-default-folder")
        #expect(harness.page?.emptyState?.actions.map(\.id) == ["read-folder"])

        try await harness.perform(try #require(notice.action), row: nil)
        #expect(harness.toasts.last?.title == "Using the Default Folder")
        #expect(harness.rows.map(\.title) == ["Groceries"])
        #expect(harness.page?.notice == nil)
    }

    @Test func aMissingFolderOrAFileSaysSo() async throws {
        let fakes = FakeServices()
        let gone = fakes.storage.homeDirectory.appending(path: "Gone")
        fakes.context(featureID: NoteIDs.feature).settings[NotesSettings.folder] = gone.path
        let harness = try await FeatureHarness.make(fakes: fakes)
        #expect(harness.library.index.problem == .missing)
        #expect(!FileManager.default.fileExists(atPath: gone.path))
        let row = try #require(harness.instantAnswers(for: "note keep this").first?.rows.first)
        await #expect(throws: ActionFailure.self) { try await harness.performRoot("save", on: row) }

        try harness.write("a file.md", "x", in: harness.home)
        let file = harness.home.appending(path: "a file.md")
        harness.fakes.fileDialogs.filesToChoose = [file]
        try await harness.pressSettingsButton("Choose Folder…")
        #expect(harness.library.index.problem == .notAFolder)
        #expect(harness.toasts.last?.title == "Notes Folder Is Not a Folder")
    }

    @Test func aRunOutsideTheLiveAppTouchesOnlyItsOwnFolders() async throws {
        let fakes = FakeServices()
        let outside = FileManager.default.temporaryDirectory.appending(path: "notes-outside-\(UUID().uuidString)")
        fakes.context(featureID: NoteIDs.feature).settings[NotesSettings.folder] = outside.path
        let harness = try await FeatureHarness.make(fakes: fakes)
        #expect(harness.library.index.problem == .outsideRun)
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        #expect(harness.feature.status?.title == "Notes Folder Is Outside This Run")
    }

    @Test func aFolderAnywhereIsClassifiedByPathAlone() {
        let home = URL(filePath: "/Users/someone")
        func place(_ path: String) -> GuardedPlace? { GuardedPlace.of(URL(filePath: path), home: home) }
        #expect(place("/Users/someone/Desktop/Notes") == .desktop)
        #expect(place("/Users/someone/documents") == .documents)
        #expect(place("/Users/someone/Downloads/x/y") == .downloads)
        #expect(place("/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/Notes") == .iCloudDrive)
        #expect(place("/Volumes/Stick/Notes") == .volume)
        #expect(place("/Users/someone/Library/Containers/x") == .appData)
        #expect(place("/Users/someone/Writing") == nil)
        #expect(place("/Users/someone/DesktopNotes") == nil)
        #expect(place("/Users/someone/Desktop/../Writing") == nil)
    }
}
