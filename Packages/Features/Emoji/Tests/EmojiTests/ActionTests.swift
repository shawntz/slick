import Kit
import KitTesting
import Testing

@testable import Emoji

@Suite("Actions", .timeLimit(.minutes(1)))
struct ActionTests {
    /// A harness with the grid open on one emoji.
    private func select(_ title: String, fakes: FakeServices = FakeServices()) async throws -> FeatureHarness<
        EmojiFeature
    > {
        let harness = await loadedHarness(fakes)
        try await harness.run("search")
        try await harness.setQuery(title.lowercased())
        try harness.select(title: title)
        return harness
    }

    @Test func returnPastesAndTheActionNamesTheEmoji() async throws {
        let harness = try await select("Grinning Face")
        let actions = harness.actions()
        #expect(
            actions.map(\.id) == ["paste", "copy", "pin", "copy-name", "copy-code-points"],
            "no skin tone menus for a face")
        #expect(actions.first?.title == "Paste Grinning Face", "the action bar shows the selected name")
        #expect(actions.first?.requires == [.accessibility])
        let outcome = try await harness.performPrimary()
        #expect(outcome.kind == .close(hud: nil))
        #expect(harness.fakes.pasteboard.pastedTexts == ["😀"])
        #expect(harness.huds.isEmpty)
        #expect(harness.issues.isEmpty)
        #expect(harness.pendingIssues.isEmpty)
    }

    @Test func commandReturnCopies() async throws {
        let harness = try await select("Grinning Face")
        try await harness.performSecondary()
        #expect(harness.fakes.pasteboard.copiedTexts == ["😀"])
        #expect(harness.fakes.pasteboard.pastedTexts.isEmpty)
        #expect(harness.huds == ["Copied 😀"])
        #expect(harness.fakes.usage.recorded == [emojiID("😀")])
    }

    @Test func copiesTheNameAndTheCodePoints() async throws {
        let fakes = FakeServices()
        let harness = try await select("Thumbs Up", fakes: fakes)
        harness.context.settings[EmojiSettings.skinTone] = .medium
        try await harness.perform("copy-name")
        try await harness.perform("copy-code-points")
        #expect(fakes.pasteboard.copiedTexts == ["Thumbs Up", "U+1F44D U+1F3FD"])
        #expect(harness.huds == ["Copied the Name", "Copied the Code Points"])
        #expect(fakes.usage.recorded.isEmpty, "copying the name is not a use of the emoji")

        let symbol = try await select("Euro")
        try await symbol.perform("copy-code-points")
        #expect(symbol.fakes.pasteboard.copiedTexts == ["U+20AC"])
        #expect(EmojiEntry.codePoints(of: "❤️") == "U+2764 U+FE0F")
    }

    @Test func returnCanCopyInsteadAndThenNeedsNoPermission() async throws {
        let fakes = FakeServices()
        fakes.permissions.set(.accessibility, to: .denied)
        let harness = try await select("Rocket", fakes: fakes)
        await #expect(throws: HarnessError.permissionRequired([.accessibility])) { try await harness.performPrimary() }
        #expect(fakes.pasteboard.pastedTexts.isEmpty)

        harness.context.settings[EmojiSettings.returnAction] = .copy
        #expect(harness.actions().prefix(2).map(\.id) == ["copy", "paste"])
        #expect(harness.actions().first?.title == "Copy Rocket")
        try await harness.performPrimary()
        #expect(fakes.pasteboard.copiedTexts == ["🚀"])
        #expect(harness.huds == ["Copied 🚀"])
    }

    @Test func aFailedPasteReachesTheUser() async throws {
        let fakes = FakeServices()
        fakes.pasteboard.pasteFailure = .targetDidNotActivate
        let harness = try await select("Rocket", fakes: fakes)
        harness.throwsActionErrors = false
        try await harness.performPrimary()
        #expect(harness.actionErrors.count == 1)
        #expect(fakes.usage.recorded.isEmpty, "a paste that failed is not a use")
    }

    @Test func emojiWithTonesOfferBothToneMenusWithTheirShortcuts() async throws {
        let harness = try await select("Thumbs Up")
        let actions = harness.actions()
        #expect(
            actions.map(\.id) == [
                "paste", "copy", "paste-with-skin-tone", "copy-with-skin-tone", "pin", "copy-name",
                "copy-code-points",
            ])
        let shortcuts = actions.compactMap(\.shortcut)
        #expect(Set(shortcuts).count == shortcuts.count, "no shortcut is used twice")
        #expect(actions.secondary?.id == "copy")
        #expect(harness.issues.isEmpty)
    }

    @Test func actionsWorkFromARowAlone() async throws {
        let harness = await loadedHarness()
        let entry = try entry("🐢")
        let row = EmojiRows.row(entry, tone: .none)
        try await harness.performRoot("copy", on: row)
        #expect(harness.fakes.pasteboard.copiedTexts == ["🐢"])

        let unknown = Row(
            id: ItemID(EmojiLibrary.namespace, "ffffff"), title: "Old Emoji", payload: Payload("🫠"),
            memory: .learnOnly)
        #expect(harness.rootActions(for: unknown).map(\.title) == ["Paste Old Emoji", "Copy Old Emoji"])
        try await harness.performRoot("copy", on: unknown)
        #expect(harness.fakes.pasteboard.copiedTexts.last == "🫠")
    }
}
