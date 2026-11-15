import Kit
import KitTesting
import Testing

@testable import Emoji

/// Pins: Command-period pins an emoji to the top of the grid, as people expect from other
/// launchers, and a pin outranks recent use among equal matches.
@Suite("Pins", .timeLimit(.minutes(1)))
struct PinTests {
    @Test func pinningPutsAnEmojiFirstAndUnpinningTakesItAway() async throws {
        let harness = await loadedHarness()
        try await harness.run("search")
        try await harness.setQuery("turtle")
        try harness.select(title: "Turtle")
        let pin = try #require(harness.actions().first { $0.id == "pin" })
        #expect(pin.title == EmojiStrings.pin)
        #expect(pin.shortcut == .pin)
        try await harness.perform("pin")
        #expect(harness.context.settings[EmojiSettings.pinned] == [EmojiEntry.key(for: "🐢")])
        #expect(harness.toasts.last?.title == EmojiStrings.pinnedToast("🐢"))

        try await harness.run("search")
        let first = try #require(harness.sections.first)
        #expect(first.title == EmojiStrings.pinnedSection)
        #expect(first.rows.map(\.title) == ["Turtle"])
        #expect(harness.selectedRow?.title == "Turtle")
        #expect(harness.actions().contains { $0.id == "unpin" && $0.title == EmojiStrings.unpin })

        // The action changed a setting the grid reloads on, so the harness reloads it, as the host does.
        try await harness.perform("unpin")
        #expect(harness.context.settings[EmojiSettings.pinned].isEmpty)
        #expect(harness.sections.first?.title == "Smileys & Emotion")
        #expect(harness.issues.isEmpty)
    }

    @Test func aPinShowsOnceAndBeatsRecentUseWhileSearching() async throws {
        let fakes = FakeServices()
        fakes.usage.recordUse(of: emojiID("😃"))
        fakes.usage.recordUse(of: emojiID("😄"))
        let harness = await loadedHarness(fakes)
        harness.context.settings[EmojiSettings.pinned] = [EmojiEntry.key(for: "😄"), "ffffff"]
        try await harness.run("search")
        #expect(harness.sections.map(\.title).prefix(3) == ["Pinned", "Recently Used", "Smileys & Emotion"])
        #expect(
            harness.sections[0].rows.map(\.title) == ["Grinning Face with Smiling Eyes"], "unknown keys are skipped")
        #expect(harness.sections[1].rows.map(\.title) == ["Grinning Face with Big Eyes"], "a pin is not repeated")

        // Every "Grinning ..." name starts with the query, so the pin decides among them.
        try await harness.setQuery("grinning")
        #expect(harness.titles(2) == ["Grinning Face with Smiling Eyes", "Grinning Face with Big Eyes"])
        #expect(!harness.sections.contains { $0.title == "Pinned" }, "pins hide while searching")
        let colon = harness.instantAnswers(for: ":grinning").first?.rows.first?.title
        #expect(colon == "Grinning Face with Smiling Eyes", "the colon search agrees with the grid")
    }

    @Test func pinsFollowTheCategoryAndSymbolsSettings() async throws {
        let harness = await loadedHarness()
        harness.context.settings[EmojiSettings.pinned] = [EmojiEntry.key(for: "→")]
        try await harness.run("search")
        #expect(harness.sections.first?.rows.map(\.title) == [try entry("→").name])
        #expect(harness.sections.first?.title == "Pinned")
        harness.context.settings[EmojiSettings.includeSymbols] = false
        try await harness.waitForChange()
        #expect(harness.sections.first?.title != "Pinned", "a hidden symbol is not pinned on screen")
    }
}
