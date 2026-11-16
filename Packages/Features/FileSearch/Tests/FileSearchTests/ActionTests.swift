import CoreBridge
import Foundation
import Kit
import KitTesting
import Testing

@testable import FileSearch

@Suite("Actions", .timeLimit(.minutes(1)))
@MainActor
struct ActionTests {
    private let fileOrder = [
        "open", "reveal", "open-with", "quick-look", "get-info", "share", "copy-file", "copy-path", "copy-name",
        "rename", "duplicate", "compress", "move-to", "copy-to", "move-to-trash",
    ]

    @Test func everyRowOffersTheFileActionsInGroupsWithFindersKeys() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        let row = try #require(try await fixture.harness.asyncSections(for: "notes").first?.rows.first)
        let actions = fixture.harness.rootActions(for: row)
        #expect(actions.map(\.id) == fileOrder)
        #expect(
            actions.map(\.title) == [
                "Open", "Show in Finder", "Open With", "Quick Look", "Get Info", "Share…", "Copy File", "Copy Path",
                "Copy Name", "Rename…", "Duplicate", "Compress", "Move To…", "Copy To…", "Move to Trash",
            ])
        #expect(
            actions.map(\.section) == Array(repeating: nil, count: 6) + Array(repeating: "Copy", count: 3)
                + Array(repeating: "Manage", count: 6))
        let keys = Dictionary(
            uniqueKeysWithValues: actions.compactMap { action in action.shortcut.map { (action.id, $0) } })
        #expect(
            keys == [
                "reveal": .secondaryAction, "open-with": .openWith, "quick-look": .quickLook,
                "get-info": KeyCombo(.i, .command), "copy-file": .copy, "copy-path": .copyPath, "rename": .edit,
                "duplicate": .duplicate, "move-to-trash": .remove,
            ])
        #expect(Set(keys.values).count == keys.count, "one key runs one action")
        #expect(actions.secondary?.id == "reveal", "Command-Return shows the file in Finder")
        #expect(actions.first { $0.id == "move-to-trash" }?.style == .destructive)
        #expect(fixture.harness.issues.isEmpty)

        let folder = try #require(try await fixture.harness.asyncSections(for: "Projects").first?.rows.first)
        let folderActions = fixture.harness.rootActions(for: folder).map(\.id)
        #expect(folderActions == Array(fileOrder.prefix(5)) + ["open-in-terminal"] + fileOrder.dropFirst(5))
        let app = try #require(try await fixture.harness.asyncSections(for: "Tool").first?.rows.first)
        #expect(
            !fixture.harness.rootActions(for: app).map(\.id).contains("open-in-terminal"), "a package is not a folder")
    }

    @Test func eachActionThatLooksGoesThroughTheFakes() async throws {
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
        let folder = Row(
            id: ItemID(FileRows.namespace, fixture.tree.path("Projects")), title: "Projects",
            payload: Payload(FileItem(isFolder: true)))
        try await fixture.harness.performRoot("open-in-terminal", on: folder)
        #expect(fixture.fakes.workspace.openedWith.last?.bundleID == "com.apple.Terminal")
        #expect(
            fixture.fakes.workspace.openedWith.last?.urls == [
                URL(filePath: fixture.tree.path("Projects"), directoryHint: .isDirectory)
            ])
        #expect(fixture.fakes.usage.recorded.isEmpty, "root records its own uses")
        #expect(fixture.operations.made.isEmpty, "looking changes nothing")
    }

    @Test func getInfoShowsTheItemOnAPageOfItsOwn() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        let row = try #require(try await fixture.harness.asyncSections(for: "report-2024").first?.rows.first)
        try await fixture.harness.performRoot("get-info", on: row)
        let page = try #require(fixture.harness.page)
        guard case .detail(let detailPage) = page.page else {
            Issue.record("Get Info opens a detail page")
            return
        }
        #expect(detailPage.title == "report-2024.pdf")
        #expect(fixture.harness.detail?.body == .preview(fixture.tree.url("report-2024.pdf")))
        #expect(fixture.harness.detail?.metadata.first == .label("Kind", value: "Test kind"))
        #expect(
            fixture.harness.actions().map(\.id) == [
                "open", "reveal", "open-with", "quick-look", "copy-file", "copy-path", "copy-name",
            ], "the page only looks and copies")
        // A row the scope does not allow shows what the row says, and nothing is read for it.
        let read = fixture.fileSystem.factsRead.count
        fixture.harness.pop()
        try await fixture.harness.performRoot("get-info", on: fixture.bareRow("Desktop/desktop-shot.png"))
        #expect(fixture.harness.detail?.body == nil)
        #expect(
            fixture.harness.detail?.metadata.first
                == .label("Kind", value: "Image", icon: .file(path: fixture.tree.path("Desktop/desktop-shot.png"))))
        #expect(fixture.fileSystem.factsRead.count == read)
        #expect(fixture.harness.issues.isEmpty)
    }

    @Test func renameAsksForOneNameAndTheListShowsIt() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        try await fixture.harness.run("search")
        try await fixture.harness.setQuery("report")
        try fixture.harness.select(title: "report-2024.pdf")
        let renamedID = fixture.bareRow("report-2024.pdf").id
        fixture.fakes.usage.recordUse(of: renamedID, snapshot: nil)
        try await fixture.harness.perform("rename")
        guard case .form(let form) = try #require(fixture.harness.page).page else {
            Issue.record("Rename opens a form")
            return
        }
        #expect(form.title == "Rename “report-2024.pdf”")
        #expect(form.fields.map(\.id) == ["name"])
        #expect(form.initialValues["name"] == .text("report-2024.pdf"))
        #expect(form.submitTitle == "Rename")

        for (typed, message) in [
            ("beach.jpg", "Another item in this folder is named “beach.jpg”. Choose another name."),
            ("a/b.pdf", "A name cannot contain a slash."),
            (".report.pdf", "A name that starts with a dot hides the item. Choose another name."),
        ] {
            try fixture.harness.fill("name", text: typed)
            await #expect(throws: HarnessError.self) { try await fixture.harness.submit() }
            #expect(fixture.harness.page?.formErrors["name"]?.message == message, "\(typed)")
        }
        #expect(fixture.operations.made.isEmpty, "nothing changes before the name is right")

        try fixture.harness.fill("name", text: "  report-final.pdf ")
        let outcome = try await fixture.harness.submit()
        #expect(outcome.kind == .pop)
        #expect(try fixture.names(in: "").contains("report-final.pdf"))
        #expect(fixture.harness.toasts.map(\.title).last == "Renamed to “report-final.pdf”")
        #expect(fixture.harness.rows.map(\.title) == ["report-final.pdf"], "the list shows the new name at once")
        #expect(fixture.fakes.usage.useCount(of: renamedID) == 0, "root search forgets the old name")
    }

    @Test func duplicateAndCompressShowTheirResultsAtOnce() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        try await fixture.harness.run("search")
        try await fixture.harness.setQuery("notes")
        try fixture.harness.select(title: "notes.md")
        try await fixture.harness.perform("duplicate")
        #expect(fixture.harness.rows.map(\.title).contains("notes copy.md"))
        #expect(fixture.harness.toasts.map(\.title).suffix(2) == ["Duplicating “notes.md”", "Duplicated “notes.md”"])
        #expect(fixture.harness.visibleToast?.message == "The copy is named “notes copy.md”.")
        try fixture.harness.select(title: "notes.md")
        try await fixture.harness.perform("compress")
        #expect(fixture.harness.rows.map(\.title).contains("notes.md.zip"))
        #expect(fixture.harness.visibleToast?.title == "Compressed “notes.md”")
        #expect(fixture.harness.visibleToast?.message == "The archive is named “notes.md.zip”.")
        #expect(try fixture.names(in: "").contains("notes.md"), "the original stays")
        #expect(fixture.operations.made == ["duplicate", "compress"])
    }

    @Test func moveToAndCopyToAskForAFolderAndNeverReplace() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        try await fixture.harness.run("search")
        try await fixture.harness.setQuery("beach")
        try fixture.harness.select(title: "beach.jpg")
        // Cancelling the dialog does nothing.
        try await fixture.harness.perform("move-to")
        #expect(fixture.fakes.fileDialogs.openRequests.last?.canChooseDirectories == true)
        #expect(fixture.fakes.fileDialogs.openRequests.last?.canChooseFiles == false, "folders only")
        #expect(fixture.fakes.fileDialogs.openRequests.last?.title == "Choose a folder to move “beach.jpg” into.")
        #expect(fixture.operations.made.isEmpty)

        // An open panel hands back a folder with a trailing slash.
        fixture.fakes.fileDialogs.filesToChoose = [
            URL(filePath: fixture.tree.path("Archive"), directoryHint: .isDirectory)
        ]
        try await fixture.harness.perform("copy-to")
        #expect(try fixture.names(in: "Archive").contains("beach.jpg"))
        #expect(fixture.harness.visibleToast?.title == "Copied to “Archive”")
        #expect(fixture.harness.rows.compactMap(\.subtitle).sorted() == ["~", "~/Archive"], "both show at once")

        try fixture.harness.select(fixture.bareRow("beach.jpg").id)
        let original = try #require(fixture.harness.selectedRow)
        let moveTo = try #require(fixture.harness.actions().first { $0.id == "move-to" })
        fixture.harness.throwsActionErrors = false
        try await fixture.harness.perform(moveTo, row: original)
        #expect(fixture.harness.visibleToast?.title == "Could Not Move")
        #expect(
            fixture.harness.visibleToast?.message
                == "“Archive” already holds an item named “beach.jpg”, so nothing was moved.")
        #expect(try fixture.size(of: "Archive/beach.jpg") == 8 && fixture.names(in: "").contains("beach.jpg"))

        try fixture.tree.remove("Archive/beach.jpg")
        fixture.harness.throwsActionErrors = true
        try await fixture.harness.perform(moveTo, row: original)
        #expect(!(try fixture.names(in: "").contains("beach.jpg")))
        #expect(fixture.harness.visibleToast?.title == "Moved to “Archive”")
        #expect(fixture.harness.rows.map(\.subtitle) == ["~/Archive"], "the list shows where it went")
    }

    @Test func moveToTrashAsksFirstThenTheListDropsIt() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        try await fixture.harness.run("search")
        try await fixture.harness.setQuery("report-2024")
        try fixture.harness.select(title: "report-2024.pdf")
        let trashedID = fixture.bareRow("report-2024.pdf").id
        fixture.fakes.usage.recordUse(of: trashedID, snapshot: nil)
        fixture.harness.confirmationAnswer = false
        try await fixture.harness.perform("move-to-trash")
        #expect(fixture.operations.made.isEmpty, "declining keeps the file")
        fixture.harness.confirmationAnswer = true
        try await fixture.harness.perform("move-to-trash")
        #expect(fixture.harness.confirmations.map(\.title).last == "Move “report-2024.pdf” to the Trash?")
        #expect(fixture.operations.made == ["trash"])
        #expect(!(try fixture.names(in: "").contains("report-2024.pdf")))
        #expect(fixture.harness.toasts.map(\.title).last == "Moved to Trash")
        #expect(fixture.harness.rows.isEmpty, "the index learned of the move before the page reloaded")
        #expect(fixture.fakes.usage.useCount(of: trashedID) == 0)
        #expect(fixture.fakes.workspace.trashed.isEmpty, "the feature's own service moved it")
    }

    /// A walk can hold the index queue for minutes on a large home folder. A change does not wait
    /// for it: the batch follows the walk.
    @Test func aChangeDoesNotWaitForAWalkToEnd() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        fixture.maker.holdNextBuild()
        fixture.feature.context.settings[FileSearchSettings.includesHidden] = true
        await fixture.maker.waitForHeldBuild()
        #expect(fixture.feature.controller.summary.isWalking)
        // Should the change wait for the walk after all, the suite's time limit stops the walk, so
        // the run fails and ends rather than hangs.
        let walk = fixture.feature.controller.cancellation
        _ = try await withTaskCancellationHandler {
            try await fixture.harness.performRoot("duplicate", on: fixture.bareRow("notes.md"))
        } onCancel: {
            walk?.cancel()
        }
        #expect(!Task.isCancelled, "the change finished while the walk still ran")
        #expect(try fixture.names(in: "").contains("notes copy.md"))
        #expect(fixture.harness.visibleToast?.title == "Duplicated “notes.md”")
        await fixture.harness.deactivate()
        #expect(fixture.maker.stoppedWalks == 1)
    }

    @Test func anItemInAPlaceNotSearchedIsLeftAsItIs() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        fixture.harness.throwsActionErrors = false
        let row = fixture.bareRow("Desktop/desktop-shot.png")
        for action in ["duplicate", "compress", "move-to-trash"] {
            try await fixture.harness.performRoot(action, on: row)
            #expect(
                fixture.harness.visibleToast?.message
                    == "“desktop-shot.png” is in a protected place File Search does not search now, so it was left as it is.",
                "\(action)")
        }
        #expect(fixture.operations.made.isEmpty)
        #expect(try fixture.names(in: "Desktop") == ["desktop-shot.png"])
    }

    @Test func aRowRebuiltFromASnapshotStillActs() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        let folder = fixture.bareRow("Projects")
        #expect(fixture.harness.rootActions(for: folder).map(\.id) == fileOrder)
        try await fixture.harness.performRoot("copy-path", on: folder)
        #expect(fixture.fakes.pasteboard.copiedTexts == [fixture.tree.path("Projects")])
        let encoded = try JSONEncoder().encode(
            try #require(try await fixture.harness.asyncSections(for: "Projects").first?.rows.first))
        let decoded = try JSONDecoder().decode(Row.self, from: encoded)
        #expect(FileRows.item(of: decoded).isFolder)
        #expect(FileRows.url(of: decoded).hasDirectoryPath)
        #expect(fixture.harness.rootActions(for: decoded).map(\.id).contains("open-in-terminal"))
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
