import Kit
import KitTesting
import Testing

@testable import Emoji

@Suite("Recently used", .timeLimit(.minutes(1)))
struct RecentsTests {
    @Test func usesFromTheGridFillRecentlyUsedMostRecentFirst() async throws {
        let harness = await loadedHarness()
        for name in ["Turtle", "Rocket"] {
            try await harness.run("search")
            try await harness.setQuery(name.lowercased())
            try harness.select(title: name)
            try await harness.performPrimary()
        }
        #expect(harness.fakes.usage.recorded == [emojiID("🐢"), emojiID("🚀")])

        try await harness.run("search")
        let recent = try #require(harness.sections.first)
        #expect(recent.title == "Recently Used")
        #expect(recent.rows.map(\.title) == ["Rocket", "Turtle"])
        #expect(harness.selectedRow?.title == "Rocket", "the last emoji is one Return away")
        #expect(harness.sections[1].title == "Smileys & Emotion")
    }

    @Test func recentlyUsedHidesWhileSearchingButStillRanksMatches() async throws {
        let fakes = FakeServices()
        fakes.usage.recordUse(of: emojiID("😃"))
        let harness = await loadedHarness(fakes)
        try await harness.run("search")
        #expect(harness.sections.first?.rows.map(\.title) == ["Grinning Face with Big Eyes"])
        try await harness.setQuery("smile")
        #expect(!harness.sections.contains { $0.title == "Recently Used" })
        #expect(harness.titles(1) == ["Grinning Face with Big Eyes"], "a recent use beats the common smile")
        let answer = try #require(harness.instantAnswers(for: ":smile").first)
        #expect(answer.rows.first?.title == "Grinning Face with Big Eyes", "colon search ranks it first too")
    }

    @Test func theCountSettingLimitsAndHidesTheSection() async throws {
        let fakes = FakeServices()
        for glyph in ["🐢", "🚀", "🍕"] {
            fakes.usage.recordUse(of: emojiID(glyph))
            fakes.clock.advance(by: .seconds(60))
        }
        let harness = await loadedHarness(fakes)
        harness.context.settings[EmojiSettings.recentCount] = 2
        try await harness.run("search")
        #expect(harness.sections.first?.rows.map(\.title) == ["Pizza", "Rocket"])

        harness.context.settings[EmojiSettings.recentCount] = 0
        try await harness.waitForChange()
        #expect(harness.sections.first?.title == "Smileys & Emotion")
    }

    @Test func recentsSkipUnknownItemsAndHiddenSymbols() async throws {
        let fakes = FakeServices()
        fakes.usage.recordUse(of: ItemID(EmojiLibrary.namespace, "ffffff"))
        fakes.usage.recordUse(of: emojiID("→"))
        fakes.clock.advance(by: .seconds(1))
        fakes.usage.recordUse(of: emojiID("🐢"))
        let harness = await loadedHarness(fakes)
        try await harness.run("search")
        #expect(harness.sections.first?.rows.map(\.title) == ["Turtle", "Right-Pointing Arrow"])
        harness.context.settings[EmojiSettings.includeSymbols] = false
        try await harness.waitForChange()
        #expect(harness.sections.first?.rows.map(\.title) == ["Turtle"])
    }

    @Test func clearingRecentlyUsedAsksFirst() async throws {
        let fakes = FakeServices()
        fakes.usage.recordUse(of: emojiID("🐢"))
        fakes.usage.recordUse(of: emojiID("🚀"))
        let harness = await loadedHarness(fakes)

        harness.confirmationAnswer = false
        try await harness.pressSettingsButton("Clear Recently Used")
        #expect(harness.confirmations.map(\.title) == ["Clear Recently Used Emoji?"])
        #expect(fakes.usage.recentlyUsed(namespace: "emoji", limit: 10).count == 2, "declined: nothing changes")

        harness.confirmationAnswer = true
        try await harness.pressSettingsButton("Clear Recently Used")
        #expect(fakes.usage.recentlyUsed(namespace: "emoji", limit: 10).isEmpty)
        #expect(harness.toasts.last?.title == "Cleared Recently Used Emoji")
        try await harness.run("search")
        #expect(harness.sections.first?.title == "Smileys & Emotion")
    }
}
