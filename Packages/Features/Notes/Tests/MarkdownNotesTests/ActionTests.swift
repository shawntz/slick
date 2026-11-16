import Darwin
import Foundation
import Kit
import KitTesting
import Testing

@testable import MarkdownNotes

@Suite("Note actions", .timeLimit(.minutes(1)))
struct ActionTests {
    static func groceries() async throws -> FeatureHarness<NotesFeature> {
        let harness = try await FeatureHarness.make([
            ("Groceries.md", Sample.groceries), ("Budget 2027.md", Sample.budget),
        ])
        try await harness.openSearch()
        try harness.select(title: "Groceries")
        return harness
    }

    static func modified(_ harness: FeatureHarness<NotesFeature>, _ name: String) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: harness.defaultFolder.appending(path: name).path)[
            .modificationDate] as? Date
    }

    @Test func editingSavesTheFileAndRenamesItWithTheTitle() async throws {
        let harness = try await Self.groceries()
        try await harness.perform("pin")
        try harness.select(title: "Groceries")
        try await harness.perform("edit")
        try harness.fill("title", text: "Market List")
        try harness.fill("body", text: "Milk, eggs and bread")
        try await harness.submit()
        #expect(harness.toasts.last?.title == "Saved Note")
        #expect(try harness.names() == ["Budget 2027.md", "Market List.md"])
        #expect(try harness.text(of: "Market List.md") == "# Market List\n\nMilk, eggs and bread\n\n#errands\n")
        // The list below shows the new title, still pinned.
        #expect(harness.sections.first?.rows.map(\.title) == ["Market List"])
        #expect(harness.library.pinned == ["Market List.md"])
    }

    @Test func savingWithoutAChangeWritesNothing() async throws {
        let harness = try await Self.groceries()
        let before = try Self.modified(harness, "Groceries.md")
        harness.fakes.clock.advance(by: .seconds(60))
        try await harness.perform("edit")
        try await harness.submit()
        #expect(try Self.modified(harness, "Groceries.md") == before)
        #expect(try harness.text(of: "Groceries.md") == Sample.groceries)
    }

    @Test func aNoteChangedElsewhereWhileEditingKeepsBothVersions() async throws {
        let harness = try await Self.groceries()
        try await harness.perform("edit")
        try harness.fill("body", text: "My version")
        // Another app saves the note while the form is open.
        try harness.write("Groceries.md", "# Groceries\n\nTheir version\n", modified: harness.fakes.clock.now)
        try await harness.submit()
        #expect(harness.toasts.last?.title == "Saved as a New Note")
        #expect(try harness.text(of: "Groceries.md") == "# Groceries\n\nTheir version\n")
        #expect(try harness.text(of: "Groceries 2.md") == "# Groceries\n\nMy version\n\n#errands\n")
    }

    @Test func aNoteDeletedElsewhereWhileEditingIsSavedAsANewNote() async throws {
        let harness = try await Self.groceries()
        try await harness.perform("edit")
        try harness.fill("body", text: "Still wanted")
        try FileManager.default.removeItem(at: harness.defaultFolder.appending(path: "Groceries.md"))
        try await harness.submit()
        #expect(harness.toasts.last?.title == "Saved as a New Note")
        #expect(try harness.text(of: "Groceries.md") == "# Groceries\n\nStill wanted\n\n#errands\n")
    }

    @Test func savingKeepsTheNotesPermissionsAndExtendedAttributes() async throws {
        let harness = try await Self.groceries()
        let path = harness.defaultFolder.appending(path: "Groceries.md").path
        #expect(chmod(path, 0o600) == 0)
        let value = Array("red".utf8)
        #expect(setxattr(path, "org.example.label", value, value.count, 0, 0) == 0)
        await harness.library.rescan()
        try harness.select(title: "Groceries")
        try await harness.perform("edit")
        try harness.fill("body", text: "Changed")
        try await harness.submit()
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        var buffer = [UInt8](repeating: 0, count: 16)
        let size = getxattr(path, "org.example.label", &buffer, buffer.count, 0, 0)
        #expect(size == 3)
        #expect(Array(buffer.prefix(3)) == value)
        #expect(try harness.text(of: "Groceries.md") == "# Groceries\n\nChanged\n\n#errands\n")
    }

    @Test func copyAndPasteHandTheWholeNoteOn() async throws {
        let harness = try await Self.groceries()
        try await harness.perform("copy-markdown")
        #expect(harness.huds.last == HUD("Copied Markdown"))
        try await harness.openPanel()
        try harness.select(title: "Groceries")
        try await harness.perform("copy-plain-text")
        #expect(harness.fakes.pasteboard.copiedTexts == [Sample.groceries, "Groceries\n\nMilk and eggs\n\n#errands"])
        try await harness.openPanel()
        try harness.select(title: "Groceries")
        try await harness.perform("paste")
        #expect(harness.fakes.pasteboard.pastedTexts == [Sample.groceries])
    }

    @Test func pasteAsksForAccessibilityFirst() async throws {
        let fakes = FakeServices(permissions: .notDetermined)
        let harness = try await FeatureHarness.make([("Groceries.md", Sample.groceries)], fakes: fakes)
        try await harness.openSearch()
        try harness.select(title: "Groceries")
        await #expect(throws: HarnessError.permissionRequired([.accessibility])) { try await harness.perform("paste") }
        #expect(fakes.pasteboard.pastes.isEmpty)
    }

    @Test func pinningChangesNothingInTheNote() async throws {
        let harness = try await Self.groceries()
        let before = try Self.modified(harness, "Groceries.md")
        try await harness.perform("pin")
        #expect(try harness.text(of: "Groceries.md") == Sample.groceries)
        #expect(try Self.modified(harness, "Groceries.md") == before)
        let pins = try String(contentsOf: harness.context.storage.dataFile("pins.json"), encoding: .utf8)
        #expect(pins.contains("\"default\" : [\n      \"Groceries.md\""))
        try harness.select(title: "Groceries")
        #expect(harness.actions().first { $0.id == "pin" }?.title == "Unpin Note")
        try await harness.perform("pin")
        #expect(harness.library.pinned.isEmpty)
        #expect(harness.toasts.last?.title == "Unpinned Note")
    }

    @Test func renamingChangesOnlyTheTitleLineAndTheFileName() async throws {
        let harness = try await FeatureHarness.make([("Draft.md", "Draft\r\nkeep   this\r\n\r\n#idea\r\n")])
        try await harness.openSearch()
        try harness.select(title: "Draft")
        try await harness.perform("rename")
        #expect(harness.page?.formValues.text("title") == "Draft")
        try harness.fill("title", text: "Final: v2")
        try await harness.submit()
        #expect(harness.toasts.last?.title == "Renamed to “Final: v2”")
        #expect(try harness.names() == ["Final- v2.md"])
        #expect(try harness.text(of: "Final- v2.md") == "Final: v2\r\nkeep   this\r\n\r\n#idea\r\n")
    }

    @Test func duplicatingCopiesTheBytesAndOffersToEditTheCopy() async throws {
        let harness = try await Self.groceries()
        try await harness.perform("duplicate")
        #expect(harness.toasts.last?.title == "Duplicated “Groceries”")
        #expect(try harness.text(of: "Groceries 2.md") == Sample.groceries)
        try await harness.performToastAction()
        #expect(harness.page?.formValues.text("title") == "Groceries")
        try harness.fill("title", text: "Groceries Copy")
        try await harness.submit()
        #expect(try harness.names() == ["Budget 2027.md", "Groceries Copy.md", "Groceries.md"])
    }

    @Test func showInFinderAndOpenGoThroughTheWorkspace() async throws {
        let harness = try await Self.groceries()
        try await harness.perform("reveal")
        #expect(harness.fakes.workspace.revealed == [harness.defaultFolder.appending(path: "Groceries.md")])
    }

    @Test func deletingAsksByNameThenMovesTheFileToTheTrash() async throws {
        let harness = try await Self.groceries()
        let id = NoteIDs.row("Groceries.md")
        harness.fakes.usage.recordUse(of: id, snapshot: nil)
        try await harness.perform("pin")
        try harness.select(title: "Groceries")

        harness.confirmationAnswer = false
        try await harness.perform("move-to-trash")
        #expect(harness.confirmations.last?.title == "Move “Groceries” to the Trash?")
        #expect(harness.fakes.workspace.trashed.isEmpty)

        harness.confirmationAnswer = true
        try await harness.perform("move-to-trash")
        #expect(harness.fakes.workspace.trashed == [harness.defaultFolder.appending(path: "Groceries.md")])
        #expect(harness.fakes.usage.useCount(of: id) == 0)
        #expect(harness.library.pinned.isEmpty)
        #expect(harness.toasts.last?.title == "Moved to Trash")
    }

    @Test func aDestructiveActionChecksTheFileAgainFirst() async throws {
        let harness = try await Self.groceries()
        let outside = harness.home.appending(path: "Outside")
        try harness.write("secret.md", "# Secret\n", in: outside)
        // Between the scan and the press, the note becomes a link to a file outside the folder.
        let note = harness.defaultFolder.appending(path: "Groceries.md")
        try FileManager.default.removeItem(at: note)
        try FileManager.default.createSymbolicLink(at: note, withDestinationURL: outside.appending(path: "secret.md"))
        await #expect(throws: Strings.notALink) { try await harness.perform("move-to-trash") }
        await #expect(throws: Strings.notALink) { try await harness.perform("copy-markdown") }
        await #expect(throws: Strings.notALink) { try await harness.perform("open") }
        #expect(harness.fakes.workspace.trashed.isEmpty)
        #expect(harness.fakes.workspace.opened.isEmpty)
        #expect(harness.fakes.pasteboard.copied.isEmpty)
    }

    @Test func aCraftedRowGetsNoActions() async throws {
        let harness = try await Self.groceries()
        for key in ["../Groceries.md", "Groceries.md/..", ".hidden.md", "Groceries", "/etc/hosts.md", "Gone.md"] {
            let row = Row(id: ItemID(NoteIDs.namespace, key), title: "Groceries")
            #expect(harness.rootActions(for: row).isEmpty, "\(key)")
        }
        let capture = Row(id: ItemID(NoteIDs.captureNamespace, "new"), title: "Create Note")
        #expect(harness.rootActions(for: capture).isEmpty)
    }
}
