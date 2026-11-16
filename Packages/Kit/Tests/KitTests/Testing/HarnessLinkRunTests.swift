import Kit
import KitTesting
import Testing

/// The harness tells a handler that a link started its run, as the host does: for a deep link
/// launch, and for every run while a test says the panel session is one a link opened.
@Suite("FeatureHarness: runs a link started", .timeLimit(.minutes(1)))
struct HarnessLinkRunTests {
    final class Recorder: Feature {
        static let manifest = FeatureManifest(id: "recorder", name: "Recorder", icon: .glyph("R"))
        private(set) var seen: [Bool] = []
        init(context: FeatureContext) {}

        var commands: [Command] {
            [
                Command(id: "note", title: "Note", takesRootQueryOnTab: true) { context in
                    self.seen.append(context.startedByLink)
                    return .keepOpen
                }
            ]
        }
    }

    @Test func aHandlerHearsWhenALinkStartedItsRun() async throws {
        let harness = FeatureHarness(Recorder.self)
        try await harness.run("note")
        try await harness.run("note", launch: .deeplink)
        harness.inLinkSession = true
        try await harness.pressTab("typed")
        try await harness.run("note", launch: .command)
        #expect(harness.feature.seen == [false, true, true, true])
    }

    @Test func aContextStartsAsNotStartedByALink() {
        let harness = FeatureHarness(Recorder.self)
        let context = ActionContext(feature: harness.context, host: harness, launch: .tabFromRoot)
        #expect(!context.startedByLink)
    }
}
