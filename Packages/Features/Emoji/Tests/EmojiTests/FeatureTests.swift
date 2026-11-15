import Kit
import KitTesting
import Testing

@testable import Emoji

@Suite("Feature and settings", .timeLimit(.minutes(1)))
struct FeatureTests {
    @Test func declaresOneCommandAndTheColonProvider() throws {
        let harness = FeatureHarness(EmojiFeature.self)
        #expect(harness.issues.isEmpty)
        #expect(EmojiFeature.manifest.id == "emoji")
        #expect(EmojiFeature.manifest.permissions.map(\.permission) == [.accessibility])
        #expect(EmojiFeature.manifest.permissions.first?.reason.hasPrefix("Paste") == true)
        let command = try harness.command("search")
        #expect(command.title == "Search Emoji and Symbols")
        #expect(command.itemID(feature: "emoji").rawValue == "cmd:emoji.search")
        #expect(harness.feature.liveProviders.map(\.namespace) == ["emoji"])
    }

    @Test func theGridWaitsForTheDataWhenOpenedBeforeActivation() async throws {
        let harness = FeatureHarness(EmojiFeature.self)
        try await harness.run("search")
        #expect(harness.selectedRow?.title == "Grinning Face")
    }

    @Test func thePaneOffersTheExpectedChoicesWithSafeDefaults() throws {
        let harness = FeatureHarness(EmojiFeature.self)
        let pane = try #require(harness.feature.settingsPane)
        let items = pane.sections.flatMap(\.items)
        #expect(
            items.compactMap(\.control.key?.name) == [
                "skinTone", "returnAction", "includeSymbols", "colonSearch", "recentCount",
            ])
        #expect(items.last?.title == "Clear Recently Used")
        guard case .picker(_, let tones) = items[0].control else {
            Issue.record("the skin tone is not a picker")
            return
        }
        #expect(
            tones.map(\.title) == [
                "✋  Default", "✋🏻  Light", "✋🏼  Medium-Light", "✋🏽  Medium", "✋🏾  Medium-Dark", "✋🏿  Dark",
            ])
        #expect(pane.sections.first?.footer?.contains("Emoji 18.0") == true)

        let settings = harness.context.settings
        #expect(settings[EmojiSettings.skinTone] == .none)
        #expect(settings[EmojiSettings.returnAction] == .paste)
        #expect(settings[EmojiSettings.includeSymbols])
        #expect(settings[EmojiSettings.colonSearch])
        #expect(settings[EmojiSettings.recentCount] == 16)
    }
}
