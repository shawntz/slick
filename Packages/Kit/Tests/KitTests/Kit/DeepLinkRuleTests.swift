import Kit
import KitTesting
import Testing

@Suite("Deep links", .timeLimit(.minutes(1)))
struct DeepLinkRuleTests {
    /// Hidden commands in each of the four ways a feature can declare one.
    final class Hidden: Feature {
        static let manifest = FeatureManifest(id: "hidden", name: "Hidden", icon: .symbol("eye.slash"))
        init(context: FeatureContext) {}

        var commands: [Command] {
            [
                Command(id: "paste-now", title: "Paste Now", showsInRoot: false) { _ in .close() },
                Command(id: "linkless", title: "Linkless", showsInRoot: false, allowsDeepLinks: false) { _ in
                    .close()
                },
                Command(
                    id: "asks", title: "Asks", confirmation: Confirmation("Run Asks?"), showsInRoot: false
                ) { _ in .close() },
                Command(id: "shown", title: "Shown") { _ in .close() },
            ]
        }
    }

    @Test func aCommandAllowsDeepLinksUnlessItSaysOtherwise() {
        #expect(Command(id: "a", title: "A") { _ in .close() }.allowsDeepLinks)
        #expect(!Command(id: "b", title: "B", allowsDeepLinks: false) { _ in .close() }.allowsDeepLinks)
    }

    /// Every feature follows the rule now, so it is an issue like any other, and none is pending.
    @Test func aHiddenCommandThatAsksNothingAndTakesLinksIsAnIssue() {
        let harness = FeatureHarness(Hidden.self)
        #expect(harness.issues.count == 1)
        #expect(harness.issues.first?.message.hasPrefix("command \"paste-now\" is hidden") == true)
        #expect(FeatureValidator.validate(harness.feature).count == 1)
        #expect(harness.pendingIssues.isEmpty)
    }

    @Test func checksAListOfCommandsAlone() {
        let manifest = Hidden.manifest
        let hidden = Command(id: "x", title: "X", showsInRoot: false) { _ in .close() }
        #expect(FeatureValidator.validate(commands: [hidden], manifest: manifest).count == 1)
        var safe = hidden
        safe.allowsDeepLinks = false
        #expect(FeatureValidator.validate(commands: [safe], manifest: manifest).isEmpty)
        var asks = hidden
        asks.confirmation = Confirmation("Run X?")
        #expect(FeatureValidator.validate(commands: [asks], manifest: manifest).isEmpty)
        #expect(FeatureValidator.pendingIssues(commands: [hidden]).isEmpty)
    }
}
