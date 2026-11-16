import Foundation
import Kit
import KitTesting
import Testing

@testable import MarkdownNotes

@Suite("Hardening", .timeLimit(.minutes(1)))
struct HardeningTests {
    /// A note saved in Latin-1 by an old editor: three accented letters that are not UTF-8.
    static let latin1: Data = {
        var data = Data("# Caf".utf8)
        data.append(0xE9)
        data.append(contentsOf: Data(" notes\n\nUn r".utf8))
        data.append(0xE9)
        data.append(contentsOf: Data("sum".utf8))
        data.append(0xE9)
        data.append(contentsOf: Data(" court.\n".utf8))
        return data
    }()

    /// A note TextEdit saved as UTF-16.
    static let utf16: Data =
        Data([0xFF, 0xFE]) + Data("# Wide\n\nSome text\n".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })

    static let byteOrderMark = Data([0xEF, 0xBB, 0xBF])

    private func bytes(_ harness: FeatureHarness<NotesFeature>, _ name: String) throws -> Data {
        try Data(contentsOf: harness.defaultFolder.appending(path: name))
    }

    /// Runs a change and returns the title of the failure it threw, or nil when it went through.
    private func failureTitle(_ change: () async throws -> Void) async -> String? {
        do {
            try await change()
            return nil
        } catch let failure as ActionFailure {
            return failure.title
        } catch {
            return String(describing: error)
        }
    }

    // MARK: Encodings

    @Test func aNoteThatIsNotPlainUTF8IsShownButNeverWrittenOver() async throws {
        let harness = try await FeatureHarness.make()
        try harness.writeData("Cafe.md", Self.latin1)
        try harness.writeData("Wide.md", Self.utf16)
        try await harness.announceChange()
        let titles = Set(harness.library.index.notes.map(\.title))
        #expect(titles == ["Caf\u{FFFD} notes", "Wide"], "both read as text, so both are listed and searched")

        try await harness.openSearch()
        for (name, title) in [("Cafe.md", "Caf\u{FFFD} notes"), ("Wide.md", "Wide")] {
            let before = try bytes(harness, name)
            #expect(
                await failureTitle { _ = try await harness.library.append("more", to: name) }
                    == "Note Uses Another Encoding")
            #expect(
                await failureTitle { _ = try await harness.library.rename(name, to: "Renamed") }
                    == "Note Uses Another Encoding")
            try harness.select(title: title)
            #expect(await failureTitle { try await harness.perform("edit") } == "Note Uses Another Encoding")
            #expect(await failureTitle { try await harness.perform("rename") } == "Note Uses Another Encoding")
            #expect(try bytes(harness, name) == before, "\(name) keeps every byte")
        }
        #expect(try harness.names() == ["Cafe.md", "Wide.md"])

        // Copy and Duplicate hand the note on as it is.
        try harness.select(title: "Caf\u{FFFD} notes")
        try await harness.perform("duplicate")
        #expect(try bytes(harness, "Caf\u{FFFD} notes.md") == Self.latin1)
    }

    @Test func aNoteWithAByteOrderMarkKeepsItThroughEveryChange() async throws {
        let harness = try await FeatureHarness.make()
        try harness.writeData("List.md", Self.byteOrderMark + Data("# List\n\nOne\n".utf8))
        try await harness.announceChange()
        #expect(harness.library.index.notes.map(\.title) == ["List"])

        _ = try await harness.library.append("Two", to: "List.md")
        #expect(try bytes(harness, "List.md") == Self.byteOrderMark + Data("# List\n\nOne\n\nTwo\n".utf8))

        let renamed = try await harness.library.rename("List.md", to: "Things")
        #expect(renamed == "Things.md")
        #expect(try bytes(harness, "Things.md") == Self.byteOrderMark + Data("# Things\n\nOne\n\nTwo\n".utf8))

        try await harness.openSearch()
        try harness.select(title: "Things")
        try await harness.perform("edit")
        try harness.fill("body", text: "Three")
        try await harness.submit()
        #expect(try bytes(harness, "Things.md") == Self.byteOrderMark + Data("# Things\n\nThree\n".utf8))
        #expect(harness.issues.isEmpty)
    }

    // MARK: Guarded folders

    @Test func aReadForOneFolderNeverReadsAnotherThatWaitsForTheUser() async throws {
        let fakes = FakeServices()
        let recording = RecordingDisk(base: NoteDiskKey.isolated(fakes.context(featureID: NoteIDs.feature)))
        fakes.override(NoteDiskKey.self, with: recording)
        let harness = try await FeatureHarness.make(fakes: fakes)
        let desktop = harness.home.appending(path: "Desktop").appending(path: "Jots")
        try harness.write("Plans.md", "# Plans\n", in: desktop)
        let library = harness.library
        let own = NoteLibrary.folder(for: harness.context)
        let guarded = NoteFolder(url: desktop, isDefault: false, guarded: .desktop)
        #expect(own.isDefault)

        // Two opens overlap, as when the folder setting changes while the feature reads its own
        // folder. The read of the feature's own folder must not land on the guarded one.
        let first = Task { await library.open(own, userAsked: false) }
        let second = Task { await library.open(guarded, userAsked: false) }
        await first.value
        await second.value
        #expect(!recording.listedFolders.contains("Jots"), "macOS would ask, and the user asked for nothing")
        #expect(!recording.readNames.contains("Plans.md"))
        #expect(library.index.folder == guarded && library.index.problem == .waitingForRead)
        #expect(harness.context.settings[NotesSettings.confirmedFolder].isEmpty)
    }

    // MARK: Odd timing

    @Test func twoNotesWithOneTitleSavedAtOnceBothKeepTheirText() async throws {
        let harness = try await FeatureHarness.make()
        async let first = harness.library.create("# Same\n\nfirst\n")
        async let second = harness.library.create("# Same\n\nsecond\n")
        let names = try await [first, second]
        #expect(Set(names) == ["Same.md", "Same 2.md"])
        let texts = try Set(names.map { try harness.text(of: $0) })
        #expect(texts == ["# Same\n\nfirst\n", "# Same\n\nsecond\n"])
    }

    @Test func aFolderThatVanishesUnderAnOpenListActsOnNothing() async throws {
        let harness = try await FeatureHarness.make()
        let folder = harness.home.appending(path: "Jots")
        try harness.write("Plans.md", "# Plans\n\nSoon\n", in: folder)
        harness.fakes.fileDialogs.filesToChoose = [folder]
        try await harness.pressSettingsButton("Choose Folder…")
        try await harness.openSearch()
        try harness.select(title: "Plans")
        try FileManager.default.removeItem(at: folder)

        // The row is still on screen. Every action that touches the file finds nothing and says so.
        for id in ["move-to-trash", "open", "reveal", "edit", "rename", "copy-markdown", "duplicate"] {
            await #expect(throws: ActionFailure.self, "\(id)") { try await harness.perform(id) }
        }
        #expect(harness.fakes.workspace.trashed.isEmpty && harness.fakes.workspace.opened.isEmpty)
        #expect(harness.fakes.workspace.revealed.isEmpty && harness.fakes.pasteboard.copiedTexts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path), "nothing made the folder again")

        try await harness.announceChange(in: folder)
        #expect(harness.page?.notice?.title == "Notes Folder Is Missing")
        #expect(harness.rows.isEmpty)
        #expect(harness.issues.isEmpty)
    }

    @Test func aRenameFormKeepsWhatAnotherAppWroteMeanwhile() async throws {
        let harness = try await FeatureHarness.make([("Groceries.md", Sample.groceries)])
        try await harness.openSearch()
        try harness.select(title: "Groceries")
        try await harness.perform("rename")
        try harness.fill("title", text: "Market")
        try harness.write("Groceries.md", "# Groceries\n\nTheir line\n", modified: harness.fakes.clock.now)
        try await harness.submit()
        #expect(try harness.names() == ["Market.md"])
        #expect(try harness.text(of: "Market.md") == "# Market\n\nTheir line\n")
    }

    // MARK: Every action

    @Test func everyActionOnEveryKindOfRowRunsAndLeavesNoIssue() async throws {
        let notes = [("Groceries.md", Sample.groceries), ("Budget 2027.md", Sample.budget)]
        func fresh() async throws -> FeatureHarness<NotesFeature> {
            let harness = try await FeatureHarness.make(notes)
            harness.context.settings[NotesSettings.showsInRootSearch] = true
            return harness
        }

        // Search Notes.
        let listIDs = try await {
            let harness = try await fresh()
            try await harness.openSearch()
            return try harness.actionIDs(of: "Groceries")
        }()
        #expect(listIDs.count == 11 && listIDs.first == "edit" && listIDs.contains("move-to-trash"))
        for id in listIDs {
            let harness = try await fresh()
            try await harness.openSearch()
            try harness.select(title: "Groceries")
            try await harness.perform(id)
            #expect(harness.issues.isEmpty && harness.pendingIssues.isEmpty, "\(id)")
        }

        // Root search: the note's row and the quick capture row.
        let probe = try await fresh()
        let noteRow = try #require(try await probe.catalogRows().first { $0.title == "Groceries" })
        let captureRow = try #require(probe.instantAnswers(for: "note call the plumber").first?.rows.first)
        for row in [noteRow, captureRow] {
            for id in probe.rootActions(for: row).map(\.id) {
                let harness = try await fresh()
                _ = try await harness.performRoot(id, on: row)
                #expect(harness.issues.isEmpty && harness.pendingIssues.isEmpty, "\(row.title): \(id)")
            }
        }

        // A note on its own page, opened from root search.
        let pageHarness = try await fresh()
        _ = try await pageHarness.performRoot("show", on: noteRow)
        for id in pageHarness.actions().map(\.id) where id != "move-to-trash" {
            let harness = try await fresh()
            _ = try await harness.performRoot("show", on: noteRow)
            try await harness.perform(id)
            #expect(harness.issues.isEmpty && harness.pendingIssues.isEmpty, "page: \(id)")
        }
        _ = try await pageHarness.perform("move-to-trash")
        #expect(pageHarness.fakes.workspace.trashed.map(\.lastPathComponent) == ["Groceries.md"])

        // Append to Note's picker.
        let picker = try await fresh()
        try await picker.run(NoteIDs.appendCommand, arguments: [NoteIDs.textArgument: "- soap"])
        try picker.select(title: "Budget 2027")
        try await picker.performPrimary()
        #expect(try picker.text(of: "Budget 2027.md").hasSuffix("- soap\n"))
        #expect(picker.issues.isEmpty)
    }

    @Test func aMisleadingTitleIsNamedAsStoredInTheTrashQuestion() async throws {
        let harness = try await FeatureHarness.make([("Invoice.md", "# invoice\u{202E}fdp.app\n\nDue soon\n")])
        try await harness.openSearch()
        let title = try #require(harness.rows.first?.title)
        #expect(!title.unicodeScalars.contains("\u{202E}"))
        try harness.select(title: title)
        harness.confirmationAnswer = false
        try await harness.perform("move-to-trash")
        let question = try #require(harness.confirmations.last?.title)
        #expect(!question.unicodeScalars.contains("\u{202E}") && question.contains("\u{FFFD}"))
        #expect(harness.fakes.workspace.trashed.isEmpty)
    }

    // MARK: Quick capture

    @Test func quickCaptureLooksAtABoundedRunOfBlanks() {
        #expect(QuickCapture.text(in: "note " + String(repeating: " ", count: 100) + "milk") == "milk")
        #expect(QuickCapture.text(in: "note " + String(repeating: " ", count: 20_000) + "milk") == nil)
        #expect(QuickCapture.text(in: "note " + String(repeating: "\t", count: 20_000)) == nil)
        #expect(QuickCapture.text(in: "note " + String(repeating: "\u{3000}", count: 20_000) + "x") == nil)
    }
}
