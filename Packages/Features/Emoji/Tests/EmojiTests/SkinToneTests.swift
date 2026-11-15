import Kit
import KitTesting
import Testing

@testable import Emoji

@Suite("Skin tones", .timeLimit(.minutes(1)))
struct SkinToneTests {
    @Test func aToneAppliesToOnePersonAndLeavesOtherEmojiAlone() throws {
        #expect(try entry("👍").glyph(in: .medium) == "👍🏽")
        #expect(try entry("☝️").glyph(in: .dark) == "☝🏿", "the modifier replaces the variation selector")
        #expect(try entry("🧑‍💻").glyph(in: .light) == "🧑🏻‍💻")
        #expect(try entry("👍").glyph(in: .none) == "👍")
        #expect(try entry("🚀").glyph(in: .dark) == "🚀")
        #expect(try entry("😀").glyph(in: .mediumLight) == "😀")
        #expect(try entry("→").glyph(in: .dark) == "→")
    }

    @Test func aDefaultToneAppliesToEveryPersonInAMultiPersonEmoji() throws {
        #expect(try entry("🧑‍🤝‍🧑").glyph(in: .medium) == "🧑🏽‍🤝‍🧑🏽")
        #expect(try entry("🤝").glyph(in: .dark) == "🤝🏿")
        #expect(try entry("💏").glyph(in: .mediumDark) == "💏🏾")
        #expect(try entry("🧑‍🤝‍🧑").glyph(in: .light, .dark) == "🧑🏻‍🤝‍🧑🏿")
        #expect(try entry("🤝").glyph(in: .light, .mediumLight) == "🫱🏻‍🫲🏼")
        #expect(try entry("🧑‍🤝‍🧑").glyph(in: .none, .dark) == "🧑‍🤝‍🧑", "no tone for the first person keeps the base")
        #expect(try entry("👍").glyph(in: .medium, .dark) == "👍🏽", "one person uses the first tone")
    }

    @Test func theDefaultToneShowsInTheGridAndIsPasted() async throws {
        let harness = await loadedHarness()
        harness.context.settings[EmojiSettings.skinTone] = .medium
        try await harness.run("search")
        try await harness.setQuery("thumbs up")
        try harness.select(title: "Thumbs Up")
        #expect(harness.selectedRow?.icon == .glyph("👍🏽"))
        try await harness.performPrimary()
        #expect(harness.fakes.pasteboard.pastedTexts == ["👍🏽"])
        #expect(harness.fakes.usage.recorded == [emojiID("👍")], "the use counts for the emoji, whatever its tone")

        try await harness.run("search")
        try await harness.setQuery("people holding hands")
        #expect(harness.rows.first?.icon == .glyph("🧑🏽‍🤝‍🧑🏽"))
        try await harness.setQuery("rocket")
        #expect(harness.rows.first?.icon == .glyph("🚀"))
        #expect(harness.issues.isEmpty)
    }

    @Test func anOpenGridFollowsANewDefaultTone() async throws {
        let harness = await loadedHarness()
        try await harness.run("search")
        try await harness.setQuery("waving hand")
        #expect(harness.rows.first?.icon == .glyph("👋"))
        harness.context.settings[EmojiSettings.skinTone] = .dark
        try await harness.waitForChange()
        #expect(harness.rows.first?.icon == .glyph("👋🏿"))
    }

    @Test func oneEmojiCanTakeAnotherToneOnce() async throws {
        let harness = await loadedHarness()
        harness.context.settings[EmojiSettings.skinTone] = .light
        try await harness.run("search")
        try await harness.setQuery("waving hand")
        try harness.select(title: "Waving Hand")
        let tones = try await harness.submenu("paste-with-skin-tone")
        #expect(tones.map(\.title) == ["Default", "Light", "Medium-Light", "Medium", "Medium-Dark", "Dark"])
        #expect(tones.map(\.icon) == ["👋", "👋🏻", "👋🏼", "👋🏽", "👋🏾", "👋🏿"].map { Icon.glyph($0) })
        try await harness.perform(tones[5], row: harness.selectedRow)
        #expect(harness.fakes.pasteboard.pastedTexts == ["👋🏿"])
        #expect(harness.fakes.usage.recorded == [emojiID("👋")])
        #expect(harness.context.settings[EmojiSettings.skinTone] == .light, "the default stays")

        try await harness.run("search")
        try await harness.setQuery("waving hand")
        let copies = try await harness.submenu("copy-with-skin-tone")
        try await harness.perform(copies[0], row: harness.selectedRow)
        #expect(harness.fakes.pasteboard.copiedTexts.last == "👋")
        #expect(harness.huds.last == "Copied 👋")
        #expect(harness.issues.isEmpty)
    }

    @Test func twoPeopleCanTakeTwoTones() async throws {
        let harness = await loadedHarness()
        try await harness.run("search")
        try await harness.setQuery("people holding hands")
        try harness.select(title: "People Holding Hands")
        let tones = try await harness.submenu("paste-with-skin-tone")
        #expect(tones.count == 26, "the default, five uniform tones and twenty mixes")
        #expect(tones.prefix(6).allSatisfy { $0.section == nil })
        #expect(tones.dropFirst(6).allSatisfy { $0.section == "Two Skin Tones" })
        let mix = try #require(tones.first { $0.title == "Light and Dark" })
        try await harness.perform(mix, row: harness.selectedRow)
        #expect(harness.fakes.pasteboard.pastedTexts == ["🧑🏻‍🤝‍🧑🏿"])
    }

    @Test func emojiWithoutTonesOfferNoToneMenu() async throws {
        let harness = await loadedHarness()
        try await harness.run("search")
        try await harness.setQuery("rocket")
        try harness.select(title: "Rocket")
        let ids = harness.actions().map(\.id)
        #expect(!ids.contains("paste-with-skin-tone") && !ids.contains("copy-with-skin-tone"))
    }

    @Test func colonSearchUsesTheDefaultTone() async throws {
        let harness = await loadedHarness()
        harness.context.settings[EmojiSettings.skinTone] = .mediumDark
        let answer = try #require(harness.instantAnswers(for: ":thumbs up").first)
        #expect(answer.rows.first?.icon == .glyph("👍🏾"))
    }
}
