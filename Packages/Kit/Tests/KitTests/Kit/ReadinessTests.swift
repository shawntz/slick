import Kit
import KitTesting
import Testing

@Suite("Feature readiness", .timeLimit(.minutes(1)))
@MainActor struct FeatureReadinessTests {
    final class Plain: Feature {
        static let manifest = FeatureManifest(id: "plain", name: "Plain", icon: .symbol("circle"))
        init(context: FeatureContext) {}
    }

    /// A feature with no work after activation is ready at once, so the host's wait costs nothing.
    @Test func aFeatureIsReadyAtOnceByDefault() async {
        let harness = FeatureHarness(Plain.self)
        await harness.activate()
        await harness.feature.waitUntilReady()
    }
}
