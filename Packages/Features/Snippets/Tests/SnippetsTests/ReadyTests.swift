import Foundation
import Kit
import KitTesting
import Testing

@testable import Snippets

/// Activation loads the snippets in the background. Scenarios and the self-test wait for
/// `waitUntilReady()` before they type, so a keyword must answer once it returns.
@Suite("Ready", .timeLimit(.minutes(1)))
struct ReadyTests {
    @Test func waitUntilReadyReturnsOnceAKeywordAnswers() async throws {
        let harness = FeatureHarness(SnippetsFeature.self)
        try await harness.writeFile([Fixture.greeting])
        await harness.activate()
        let feature: any Feature = harness.feature
        await feature.waitUntilReady()
        #expect(harness.instantAnswers(for: "hi").first?.rows.map(\.title) == ["Greeting"])
    }
}
