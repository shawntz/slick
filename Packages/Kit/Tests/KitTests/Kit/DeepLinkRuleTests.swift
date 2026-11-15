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

    @Test func aHiddenCommandThatAsksNothingAndTakesLinksIsPending() {
        let harness = FeatureHarness(Hidden.self)
        #expect(harness.pendingIssues.count == 1)
        #expect(harness.pendingIssues.first?.message.hasPrefix("command \"paste-now\" is hidden") == true)
    }

    /// Features written before the rule still register without an issue.
    @Test func theRuleIsNotYetAnIssue() {
        let harness = FeatureHarness(Hidden.self)
        #expect(harness.issues.isEmpty)
        #expect(FeatureValidator.validate(harness.feature).isEmpty)
    }

    @Test func checksAListOfCommandsAlone() {
        let hidden = Command(id: "x", title: "X", showsInRoot: false) { _ in .close() }
        #expect(FeatureValidator.pendingIssues(commands: [hidden]).count == 1)
        var safe = hidden
        safe.allowsDeepLinks = false
        #expect(FeatureValidator.pendingIssues(commands: [safe]).isEmpty)
    }
}
