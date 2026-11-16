import Foundation
import Kit
import KitTesting
import Testing

@testable import Emoji

/// Text root search may hand the colon search that no person types: pasted paragraphs, many
/// words, unusual Unicode. Each keystroke has 100 µs on the main thread.
@Suite("Hostile input", .timeLimit(.minutes(1)))
@MainActor
struct HostileInputTests {
    nonisolated static let longQueries: [String] = [
        ":" + Array(repeating: "a", count: 5_000).joined(separator: " "),
        ":" + String(repeating: "smile", count: 20_000),
        ":" + Array(repeating: "é", count: 3_000).joined(separator: " "),
        ":" + String(repeating: "a b c d e f g h i j ", count: 50),
    ]

    @Test(arguments: longQueries)
    func aPastedParagraphAfterAColonIsRefusedAtOnce(query: String) async throws {
        let harness = await loadedHarness()
        let clock = ContinuousClock()
        var answers: [InstantAnswer] = []
        let elapsed = clock.measure { answers = harness.instantAnswers(for: query) }
        #expect(answers.isEmpty)
        #expect(elapsed < .milliseconds(500), "\(elapsed) for \(query.utf8.count) bytes")
    }

    /// Ten words is the most a query may have. Their cost is measured in release by
    /// `Benchmark.colonSearchWorstCase`, since a debug or sanitizer build is many times slower.
    @Test func tooManyWordsOrTooLongTextIsRefused() async throws {
        let harness = await loadedHarness()
        // Every "a" starts a word of many names, so only the word cap refuses the eleventh.
        #expect(!harness.instantAnswers(for: ":a a a a a a a a a a").isEmpty)
        #expect(harness.instantAnswers(for: ":a a a a a a a a a a a").isEmpty)
        #expect(!harness.instantAnswers(for: ":box drawings light diagonal upper right to lower left").isEmpty)
        #expect(harness.instantAnswers(for: ":" + String(repeating: "x", count: 65)).isEmpty)
    }

    @Test(arguments: [":thumbs up", ":grinning face with big eyes", ":flag united", ":heart"])
    func ordinaryQueriesStillAnswer(query: String) async throws {
        let harness = await loadedHarness()
        #expect(harness.instantAnswers(for: query).first?.rows.isEmpty == false)
    }

    @Test(arguments: [":\u{0}\u{0}", ":\u{202E}heart", ":😀😀", ":\u{0301}\u{0301}", ": heart"])
    func oddUnicodeAfterAColonDoesNotCrash(query: String) async throws {
        let harness = await loadedHarness()
        _ = harness.instantAnswers(for: query)
    }

    /// What scenarios and the self-test wait for before they type: once it returns, colon search
    /// answers.
    @Test func colonSearchAnswersOnceTheFeatureSaysItIsReady() async {
        let harness = FeatureHarness(EmojiFeature.self)
        await harness.activate()
        await harness.feature.waitUntilReady()
        #expect(harness.instantAnswers(for: ":heart").first?.rows.isEmpty == false)
    }

    @Test func turningTheFeatureOffAndOnKeepsTheData() async throws {
        let harness = await loadedHarness()
        await harness.deactivate()
        await harness.activate()
        await harness.feature.waitUntilLoaded()
        #expect(harness.instantAnswers(for: ":heart").first?.rows.isEmpty == false)
        try await harness.run("search")
        try await harness.setQuery("heart")
        #expect(!harness.rows.isEmpty)
    }
}
