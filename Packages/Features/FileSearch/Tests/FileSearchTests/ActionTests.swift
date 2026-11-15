import Foundation
import Kit
import KitTesting
import Testing

@testable import FileSearch

@Suite("Actions", .timeLimit(.minutes(1)))
@MainActor
struct ActionTests {
    private let order = [
        "open", "reveal", "open-with", "quick-look", "copy-file", "copy-path", "copy-name", "share", "move-to-trash",
    ]

    @Test func everyRowOffersTheFileActionsInOrder() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        let row = try #require(try await fixture.harness.asyncSections(for: "notes").first?.rows.first)
        let actions = fixture.harness.rootActions(for: row)
        #expect(actions.map(\.id) == order)
        #expect(
            actions.map(\.title) == [
                "Open", "Show in Finder", "Open With", "Quick Look", "Copy File", "Copy Path", "Copy Name", "Share…",
                "Move to Trash",
            ])
        #expect(actions.secondary?.id == "reveal", "Command-Return shows the file in Finder")
        #expect(actions.first { $0.id == "copy-file" }?.shortcut == .copy)
        #expect(actions.first { $0.id == "move-to-trash" }?.style == .destructive)
        #expect(fixture.harness.issues.isEmpty)
    }

    @Test func eachActionGoesThroughTheFakes() async throws {
        let fixture = try Fixture()
        fixture.fakes.workspace.applications = [AppInfo(bundleID: "com.example.editor", name: "Editor")]
        try await fixture.start()
        let row = fixture.bareRow("notes.md")
        let url = fixture.tree.url("notes.md")
        try await fixture.harness.performRoot("open", on: row)
        #expect(fixture.fakes.workspace.opened == [url])
        try await fixture.harness.performRoot("reveal", on: row)
        #expect(fixture.fakes.workspace.revealed == [url])
        let apps = try await fixture.harness.submenu("open-with", in: fixture.harness.rootActions(for: row), row: row)
        #expect(apps.map(\.title) == ["Editor"])
        try await fixture.harness.perform(apps[0], row: row, launch: .root)
        #expect(fixture.fakes.workspace.openedWith.map(\.bundleID) == ["com.example.editor"])
        try await fixture.harness.performRoot("quick-look", on: row)
        #expect(fixture.harness.quickLooks == [[url]])
        try await fixture.harness.performRoot("copy-file", on: row)
        try await fixture.harness.performRoot("copy-path", on: row)
        try await fixture.harness.performRoot("copy-name", on: row)
        #expect(fixture.fakes.pasteboard.copied == [.files([url]), .text(url.path), .text("notes.md")])
        #expect(fixture.harness.huds.map(\.title) == ["Copied File", "Copied Path", "Copied Name"])
        try await fixture.harness.performRoot("share", on: row)
        #expect(fixture.harness.shares == [[.file(url)]])
        #expect(fixture.fakes.usage.recorded.isEmpty, "root records its own uses")
    }

    @Test func moveToTrashAsksFirstThenForgetsTheFile() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        try await fixture.harness.run("search")
        try await fixture.harness.setQuery("report-2024")
        try fixture.harness.select(title: "report-2024.pdf")
        fixture.harness.confirmationAnswer = false
        try await fixture.harness.perform("move-to-trash")
        #expect(fixture.fakes.workspace.trashed.isEmpty, "declining keeps the file")
        fixture.harness.confirmationAnswer = true
        // The fake workspace moves nothing, so stand in for the Trash by removing the file.
        try fixture.tree.remove("report-2024.pdf")
        try await fixture.harness.perform("move-to-trash")
        #expect(fixture.harness.confirmations.map(\.title).last == "Move “report-2024.pdf” to the Trash?")
        #expect(fixture.fakes.workspace.trashed == [fixture.tree.url("report-2024.pdf")])
        #expect(fixture.harness.toasts.map(\.title).last == "Moved to Trash")
        #expect(fixture.harness.rows.isEmpty, "the index learned of the move before the page reloaded")
    }

    @Test func aRowRebuiltFromASnapshotStillActs() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        let folder = fixture.bareRow("Projects")
        #expect(fixture.harness.rootActions(for: folder).map(\.id) == order)
        try await fixture.harness.performRoot("copy-path", on: folder)
        #expect(fixture.fakes.pasteboard.copiedTexts == [fixture.tree.path("Projects")])
        let encoded = try JSONEncoder().encode(
            try #require(try await fixture.harness.asyncSections(for: "Projects").first?.rows.first))
        let decoded = try JSONDecoder().decode(Row.self, from: encoded)
        #expect(FileRows.item(of: decoded).isFolder)
        #expect(FileRows.url(of: decoded).hasDirectoryPath)
        #expect(encoded.count < 1_024)
    }

    @Test func usesOnThePageFillRecents() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        try await fixture.harness.run("search")
        #expect(fixture.harness.rows.isEmpty)
        try await fixture.harness.setQuery("old-photos")
        try await fixture.harness.performPrimary()
        #expect(fixture.fakes.workspace.opened == [fixture.tree.url("Archive/old-photos.zip")])
        #expect(fixture.fakes.usage.recorded == [fixture.bareRow("Archive/old-photos.zip").id])
        try await fixture.harness.run("search")
        #expect(fixture.harness.sections.map(\.title) == ["Recently Used"])
        #expect(fixture.harness.rows.map(\.title) == ["old-photos.zip"])
        // A recent file that is gone from the index is not shown. The event names the folder: Kit's
        // fake watcher cannot match a deleted file below /private.
        try fixture.tree.remove("Archive/old-photos.zip")
        fixture.fakes.fileWatcher.simulateChange([fixture.tree.url("Archive")])
        try await fixture.idle()
        try await fixture.harness.reloadPage()
        #expect(fixture.harness.rows.isEmpty)
    }
}
