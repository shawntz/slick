import Foundation
import Kit
import KitTesting
import Testing

@testable import Clipboard

@Suite("Actions on a history item", .timeLimit(.minutes(1)))
@MainActor
struct ActionTests {
    /// A history with three text items, newest first: "third", "second", "first".
    private func history() async throws -> ClipboardHarness {
        let clipboard = await ClipboardHarness()
        clipboard.fakes.workspace.frontmost = AppInfo(bundleID: "com.example.writer", name: "Example Writer")
        for text in ["first", "second", "third"] {
            try await clipboard.copy(text)
            clipboard.advance(minutes: 1)
        }
        try await clipboard.openHistory()
        return clipboard
    }

    @Test func textOffersPasteCopyPinSaveAndDelete() async throws {
        let clipboard = try await history()
        let actions = clipboard.harness.actions()
        #expect(
            actions.map(\.title) == [
                "Paste to Example Writer", "Copy to Clipboard", "Pin", "Save as Snippet", "Delete", "Delete All",
            ])
        #expect(actions.secondary?.title == "Copy to Clipboard")
        #expect(actions.first { $0.id == "delete" }?.style == .destructive)
        #expect(actions.first { $0.id == "delete-all" }?.confirmation != nil)
        #expect(clipboard.harness.issues.isEmpty)
    }

    @Test func eachKindOffersItsOwnActions() async throws {
        let clipboard = await ClipboardHarness()
        try await clipboard.copy([.url(Samples.link)])
        try await clipboard.openHistory()
        #expect(
            clipboard.harness.actions().map(\.id) == [
                "paste", "copy", "paste-plain-text", "open-link", "pin", "save-as-snippet", "delete", "delete-all",
            ])
        try await clipboard.copy([.files([Samples.fileA])])
        try clipboard.harness.select(at: 0)
        #expect(
            clipboard.harness.actions().map(\.id) == [
                "paste", "copy", "paste-plain-text", "open-files", "reveal", "pin", "delete", "delete-all",
            ])
        try await clipboard.copy([.image(Samples.png(width: 2, height: 2), typeIdentifier: "public.png")])
        try clipboard.harness.select(at: 0)
        #expect(clipboard.harness.actions().map(\.id) == ["paste", "copy", "pin", "delete", "delete-all"])
        #expect(clipboard.harness.issues.isEmpty)
    }

    @Test func pasteClosesThePanelFirstThenPastesAndMovesTheItemUp() async throws {
        let clipboard = try await history()
        try clipboard.harness.select(title: "first")
        try await clipboard.harness.performPrimary()
        #expect(clipboard.pasteboard.pasted == [.text("first")])
        #expect(clipboard.harness.isClosed)
        #expect(try await clipboard.keys().first == ClipboardHarness.textKey("first"))
    }

    @Test func aFailedPasteShowsAHUDBecauseThePanelClosedBeforeIt() async throws {
        let clipboard = try await history()
        clipboard.pasteboard.pasteFailure = .targetDidNotActivate
        clipboard.harness.throwsActionErrors = false
        try await clipboard.harness.performPrimary()
        #expect(clipboard.harness.huds == [.failure("Could Not Paste")])
        #expect(clipboard.harness.toasts.isEmpty)
    }

    @Test func pasteNeedsAccessibilityAndAsksOnlyThroughTheHost() async throws {
        let clipboard = try await history()
        clipboard.fakes.permissions.set(.accessibility, to: .denied)
        await #expect(throws: HarnessError.permissionRequired([.accessibility])) {
            try await clipboard.harness.performPrimary()
        }
        #expect(clipboard.pasteboard.pasted.isEmpty)
        #expect(clipboard.fakes.permissions.requests.isEmpty)
    }

    @Test func copyPutsTheItemOnTheClipboardWithAHUD() async throws {
        let clipboard = try await history()
        try clipboard.harness.select(title: "second")
        try await clipboard.harness.performSecondary()
        #expect(clipboard.pasteboard.copied == [.text("second")])
        #expect(clipboard.harness.huds == ["Copied to Clipboard"])
        #expect(try await clipboard.keys().first == ClipboardHarness.textKey("second"))
    }

    @Test func returnCanCopyInsteadAndUsedItemsCanStayWhereTheyAre() async throws {
        let clipboard = try await history()
        clipboard.settings[ClipboardSettings.primaryAction] = .copy
        clipboard.settings[ClipboardSettings.movesUsedItemsToTop] = false
        #expect(clipboard.harness.actions().prefix(2).map(\.id) == ["copy", "paste"])
        #expect(clipboard.harness.actions().secondary?.id == "paste")
        try clipboard.harness.select(title: "first")
        try await clipboard.harness.performPrimary()
        #expect(clipboard.pasteboard.copied == [.text("first")])
        #expect(try await clipboard.keys().first == ClipboardHarness.textKey("third"))
    }

    @Test func pasteAsPlainTextDropsTheStyling() async throws {
        let clipboard = await ClipboardHarness()
        try await clipboard.copy([.richText(rtf: Samples.rtf, plain: "Bold words")])
        try await clipboard.openHistory()
        try await clipboard.harness.perform("paste-plain-text")
        #expect(clipboard.pasteboard.pasted == [.text("Bold words")])
        try await clipboard.openHistory()
        try await clipboard.harness.performPrimary()
        #expect(clipboard.pasteboard.pasted.last == .richText(rtf: Samples.rtf, plain: "Bold words"))
    }

    @Test func pinningMovesTheItemToThePinnedSectionAndBack() async throws {
        let clipboard = try await history()
        try clipboard.harness.select(title: "first")
        try await clipboard.harness.perform("pin")
        #expect(clipboard.harness.sections.first?.title == "Pinned")
        #expect(clipboard.harness.sections.first?.rows.map(\.title) == ["first"])
        #expect(clipboard.harness.visibleToast?.title == "Pinned")
        try clipboard.harness.select(title: "first")
        #expect(clipboard.harness.actions().first { $0.id == "pin" }?.title == "Unpin")
        try await clipboard.harness.perform("pin")
        #expect(clipboard.harness.sections.map(\.title) == ["Today"])
    }

    @Test func saveAsSnippetHandsTheTextToSnippets() async throws {
        let clipboard = try await history()
        try clipboard.harness.select(title: "second")
        try await clipboard.harness.perform("save-as-snippet")
        #expect(
            clipboard.harness.commandRuns == [
                CommandRun(id: ItemID.command(feature: "snippets", command: "create"), arguments: ["text": "second"])
            ])
        clipboard.harness.unavailableCommands = [HistoryActions.saveAsSnippetCommand]
        #expect(!clipboard.harness.actions().contains { $0.id == "save-as-snippet" }, "hidden while Snippets is off")
    }

    @Test func openLinkAndShowInFinderGoThroughTheWorkspace() async throws {
        let clipboard = await ClipboardHarness()
        try await clipboard.copy([.url(Samples.link)])
        try await clipboard.openHistory()
        try await clipboard.harness.perform("open-link")
        #expect(clipboard.fakes.workspace.opened == [Samples.link])

        try await clipboard.copy([.files([Samples.fileA, Samples.fileB])])
        try await clipboard.openHistory()
        try await clipboard.harness.perform("reveal")
        #expect(clipboard.fakes.workspace.revealed == [Samples.fileA, Samples.fileB])
    }

    @Test func openOpensCopiedFilesAndAsksFirstForMany() async throws {
        let clipboard = await ClipboardHarness()
        try await clipboard.copy([.files([Samples.fileA, Samples.fileB])])
        try await clipboard.openHistory()
        let open = try #require(clipboard.harness.actions().first { $0.id == "open-files" })
        #expect(open.shortcut == .open)
        try await clipboard.harness.perform("open-files")
        #expect(clipboard.fakes.workspace.opened == [Samples.fileA, Samples.fileB])
        #expect(clipboard.harness.confirmations.isEmpty, "two files open without asking")

        let many = (1...12).map { URL(filePath: "/tmp/clipboard-tests/many-\($0).txt") }
        try await clipboard.copy([.files(many)])
        try await clipboard.openHistory()
        clipboard.harness.confirmationAnswer = false
        try await clipboard.harness.perform("open-files")
        #expect(clipboard.harness.confirmations.last?.title == "Open 12 Files?")
        #expect(clipboard.fakes.workspace.opened.count == 2, "declining opens nothing")
        clipboard.harness.confirmationAnswer = true
        try await clipboard.harness.perform("open-files")
        #expect(clipboard.fakes.workspace.opened.count == 14)
    }

    @Test func deleteAsksFirstThenRemovesTheItemAndItsImage() async throws {
        let clipboard = await ClipboardHarness()
        try await clipboard.copy("stays")
        try await clipboard.copy([.image(Samples.png(width: 4, height: 4), typeIdentifier: "public.png")])
        try await clipboard.openHistory()
        let image = try #require(try await clipboard.store.page(PageRequest()).items.first?.imageURL)

        clipboard.harness.confirmationAnswer = false
        try await clipboard.harness.perform("delete")
        #expect(clipboard.harness.rows.count == 2, "declining keeps it")

        clipboard.harness.confirmationAnswer = true
        try await clipboard.harness.perform("delete")
        #expect(clipboard.harness.confirmations.last?.suppressionKey == "delete-item")
        #expect(clipboard.harness.rows.map(\.title) == ["stays"])
        #expect(!FileManager.default.fileExists(atPath: image.path))
        #expect(clipboard.harness.visibleToast?.title == "Item Deleted")
    }

    @Test func deleteAllAsksFirstAndKeepsPinnedItems() async throws {
        let clipboard = try await history()
        try clipboard.harness.select(title: "second")
        try await clipboard.harness.perform("pin")
        try await clipboard.harness.perform("delete-all")
        #expect(clipboard.harness.confirmations.last?.confirmTitle == "Delete All")
        #expect(clipboard.harness.rows.map(\.title) == ["second"])
        #expect(clipboard.harness.visibleToast?.title == "Deleted 2 Items")
    }

    @Test func anItemDeletedElsewhereFailsWithAPlainMessage() async throws {
        let clipboard = try await history()
        try clipboard.harness.select(title: "first")
        try await clipboard.store.delete(ClipboardHarness.textKey("first"))
        clipboard.harness.throwsActionErrors = false
        try await clipboard.harness.performSecondary()
        #expect(clipboard.harness.toasts.last?.title == "This Item Is Gone")
        #expect(clipboard.pasteboard.copied.isEmpty)
    }
}
