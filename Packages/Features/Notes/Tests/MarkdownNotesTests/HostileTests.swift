import Darwin
import Foundation
import Kit
import KitTesting
import Testing

@testable import MarkdownNotes

@Suite("Hostile files", .timeLimit(.minutes(1)))
struct HostileTests {
    @Test func aHugeNoteIsReadUpToTheCapAndSaysSo() async throws {
        var limits = NoteLimits.standard
        limits.bytesPerNote = 4_096
        limits.previewCharacters = 1_000
        let big = "# Big\n\n" + String(repeating: "plain words ", count: 2_000) + "needle\n"
        let harness = try await FeatureHarness.make(
            [("Big.md", big), ("Small.md", "# Small\n\nneedle\n")], limits: limits)
        try await harness.openSearch()
        #expect(harness.rows.map(\.title) == ["Big", "Small"])
        let notice = try #require(harness.page?.notice)
        #expect(notice.title == "Some Notes Are Limited")
        #expect(notice.message == "1 note is longer than 4 KB. Search reads the first 4 KB.")

        // Search reads the first part only.
        try await harness.setQuery("needle")
        #expect(harness.rows.map(\.title) == ["Small"])

        try await harness.setQuery("")
        try harness.select(title: "Big")
        guard case .markdown(let shown) = try await harness.loadDetail()?.body else {
            Issue.record("no Markdown")
            return
        }
        #expect(shown.hasSuffix(Strings.cutPreview(1_000, locale: harness.fakes.clock.locale)))
        await #expect(throws: Strings.tooLong) { try await harness.perform("edit") }
        await #expect(throws: Strings.tooLong) { try await harness.perform("rename") }
        // Copy reads up to its own, larger cap.
        try await harness.perform("copy-markdown")
        #expect(harness.fakes.pasteboard.copiedTexts == [big])
    }

    @Test func filesThatAreNotTextAreLeftOut() async throws {
        let harness = try await FeatureHarness.make([("Groceries.md", Sample.groceries)])
        try harness.writeData(
            "Photo.md", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D]))
        try harness.writeData("Noise.markdown", Data((0..<2_000).map { UInt8(0x80 + $0 % 64) }))
        try FileManager.default.createDirectory(
            at: harness.defaultFolder.appending(path: "Folder.md"), withIntermediateDirectories: true)
        try harness.write("UTF16.md", "")
        let utf16 = Data([0xFF, 0xFE]) + "# Wide note\n\nfrom TextEdit\n".data(using: .utf16LittleEndian)!
        try harness.writeData("UTF16.md", utf16)
        try harness.write("Plain.txt", "# Not a note\n")
        try await harness.openSearch()
        #expect(Set(harness.rows.map(\.title)) == ["Groceries", "Wide note"])
        #expect(harness.page?.notice?.message == "2 files named like notes are not text and left out.")
    }

    @Test func aLinkIsNeverFollowedOutOfTheFolder() async throws {
        let fakes = FakeServices()
        let recording = RecordingDisk(base: NoteDiskKey.isolated(fakes.context(featureID: NoteIDs.feature)))
        fakes.override(NoteDiskKey.self, with: recording)
        let harness = try await FeatureHarness.make([("Groceries.md", Sample.groceries)], fakes: fakes)
        let outside = harness.home.appending(path: "Private")
        try harness.write("secret.md", "# Secret\n\nzebra crossing\n", in: outside)
        try FileManager.default.createSymbolicLink(
            at: harness.defaultFolder.appending(path: "Link.md"),
            withDestinationURL: outside.appending(path: "secret.md"))
        try FileManager.default.createSymbolicLink(
            at: harness.defaultFolder.appending(path: "Up.md"), withDestinationURL: URL(filePath: "../../.."))
        try await harness.openSearch()
        #expect(harness.rows.map(\.title) == ["Groceries"])
        #expect(harness.page?.notice?.message == "2 links are left out. Notes are never read through links.")
        try await harness.setQuery("zebra")
        #expect(harness.rows.isEmpty)
        #expect(!recording.readNames.contains("Link.md"))
        #expect(!recording.readNames.contains("Up.md"))
        // A row named like the link offers nothing, and a read by name refuses the link.
        #expect(harness.rootActions(for: Row(id: NoteIDs.row("Link.md"), title: "Secret")).isEmpty)
        await #expect(throws: Strings.notALink) { _ = try await harness.library.wholeText("Link.md") }
    }

    @Test func aPipeNamedLikeANoteNeverHoldsTheScan() async throws {
        let harness = try await FeatureHarness.make([("Groceries.md", Sample.groceries)])
        #expect(mkfifo(harness.defaultFolder.appending(path: "Pipe.md").path, 0o644) == 0)
        try await harness.openSearch()
        #expect(harness.rows.map(\.title) == ["Groceries"])
        #expect(harness.page?.notice?.message == "1 file named like notes is not text and left out.")
        await #expect(throws: Strings.notALink) { _ = try await harness.library.wholeText("Pipe.md") }
    }

    @Test func namesWithControlCharactersShowOnOneLine() async throws {
        let harness = try await FeatureHarness.make([
            ("Tab\there.md", ""), ("Line\nbreak.md", "first\u{202E}line\u{2028}more\n\nbody\n"),
            ("\u{200B}.md", "  \n"),
        ])
        try await harness.openSearch()
        let titles = Set(harness.rows.map(\.title))
        #expect(titles == ["Tab here", "first\u{FFFD}line more", Strings.untitledNote])
        for row in harness.rows {
            #expect(!row.title.unicodeScalars.contains { $0.properties.generalCategory == .control })
            #expect(!(row.subtitle ?? "").contains("\n"))
        }
        try harness.select(title: "first\u{FFFD}line more")
        #expect(try await harness.loadDetail()?.metadata.last == .label("File", value: "Line break.md"))
        try await harness.perform("move-to-trash")
        #expect(harness.confirmations.last?.title == "Move “first\u{FFFD}line more” to the Trash?")
        #expect(harness.fakes.workspace.trashed == [harness.defaultFolder.appending(path: "Line\nbreak.md")])
    }

    @Test func thousandsOfFilesStopAtTheCapAndKeepTheNewest() async throws {
        let harness = try await FeatureHarness.make()
        let clock = harness.fakes.clock
        for number in 0..<5_100 {
            try harness.write(
                "Note \(number).md", "# Note \(number)\n", modified: daysAgo(0, hours: Double(number), clock: clock))
        }
        try await harness.openSearch()
        #expect(harness.library.index.notes.count == 5_000)
        #expect(harness.library.index.note(named: "Note 0.md") != nil)
        #expect(harness.library.index.note(named: "Note 4999.md") != nil)
        #expect(harness.library.index.note(named: "Note 5000.md") == nil)
        #expect(
            harness.page?.notice?.message
                == "Showing the 5000 most recently changed notes. 100 notes are left out.")
        try await harness.setQuery("note 4321")
        #expect(harness.rows.map(\.title) == ["Note 4321"])
    }

    @Test func pastTheSearchBudgetOlderNotesAreFoundByTitle() async throws {
        var limits = NoteLimits.standard
        limits.searchBytes = 30
        let harness = try await FeatureHarness.make(
            [("New.md", "# New\n\nalpha words here\n"), ("Old.md", "# Old\n\nalpha words there and more\n")],
            limits: limits)
        try await harness.openSearch()
        try await harness.setQuery("alpha")
        #expect(harness.rows.map(\.title) == ["New"])
        try await harness.setQuery("old")
        #expect(harness.rows.map(\.title) == ["Old"])
        #expect(
            harness.page?.notice?.message
                == "1 note is found by title only, because the text of all notes passes 30 bytes.")
    }

    @Test func aFolderWithMoreEntriesThanTheCapIsReadInPart() async throws {
        var limits = NoteLimits.standard
        limits.entries = 5
        let notes = (0..<8).map { ("N\($0).md", "# N\($0)\n") }
        let harness = try await FeatureHarness.make(notes, limits: limits)
        #expect(harness.library.index.notes.count <= 5)
        #expect(harness.library.index.stats.entriesCut)
    }

    @Test func aNoteOnlyInTheCloudIsNeverReadByAScan() async throws {
        let fakes = FakeServices()
        let recording = RecordingDisk(
            base: NoteDiskKey.isolated(fakes.context(featureID: NoteIDs.feature)), dataless: ["Cloud plans.md"])
        fakes.override(NoteDiskKey.self, with: recording)
        let harness = try await FeatureHarness.make(
            [("Groceries.md", Sample.groceries), ("Cloud plans.md", "# Should not be read\n")], fakes: fakes)
        try await harness.openSearch()
        #expect(harness.rows.map(\.title) == ["Groceries", "Cloud plans"])
        #expect(!recording.readNames.contains("Cloud plans.md"))
        #expect(
            harness.page?.notice?.message == "1 note is in iCloud and not downloaded, so it is found by file name.")
        try harness.select(title: "Cloud plans")
        #expect(try await harness.loadDetail()?.body == .markdown(Strings.notDownloadedBody))
        #expect(!recording.readNames.contains("Cloud plans.md"))
        await #expect(throws: Strings.notDownloaded) { try await harness.perform("copy-markdown") }
    }
}
