import Foundation
import Kit
import KitTemplates
import KitTesting
import Testing

@Suite("Composing actions")
struct ActionCompositionTests {
    /// Copies an answer, records it with `then`, and records uses from its page.
    final class Answers: Feature, ListSource {
        static let manifest = FeatureManifest(id: "answers", name: "Answers", icon: .glyph("A"))
        var history: [String] = []
        init(context: FeatureContext) {}

        var commands: [Command] {
            [Command(id: "open", title: "Open") { _ in .push(.list(ListPage(self))) }]
        }

        func load(_ request: ListRequest) async throws -> ListResult {
            ListResult(rows: [Row(id: ItemID("answers", "42"), title: "42")])
        }

        func actions(for row: Row) -> [Action] {
            [
                Action.copy(row.title).then { _ in self.history.append(row.title) }.recordingUse(),
                Action.copy(title: "Copy Later") { _ in throw ActionFailure("Gone") }.with(id: "late")
                    .then { _ in self.history.append("never") },
                Action.openWith(URL(filePath: "/tmp/answer.txt")).then { _ in self.history.append("opened") },
            ]
        }
    }

    @Test func thenRunsAfterTheHandlerSucceedsOnly() async throws {
        let harness = FeatureHarness(Answers.self)
        try await harness.run("open")
        try await harness.performPrimary()
        #expect(harness.feature.history == ["42"])
        #expect(harness.fakes.usage.recorded == [ItemID("answers", "42")], "a page run counts as a use")
        await #expect(throws: ActionFailure("Gone")) { try await harness.perform("late") }
        #expect(harness.feature.history == ["42"])
    }

    @Test func thenReachesASubmenusEntries() async throws {
        let harness = FeatureHarness(Answers.self)
        harness.fakes.workspace.applications = [AppInfo(bundleID: "com.example.editor", name: "Editor")]
        try await harness.run("open")
        let apps = try await harness.submenu("open-with")
        try await harness.perform(try #require(apps.first), row: harness.selectedRow)
        #expect(harness.feature.history == ["opened"])
    }

    @Test func recordingUseLeavesRootRunsToRoot() async throws {
        let harness = FeatureHarness(Answers.self)
        try await harness.run("open")
        try await harness.perform(try #require(harness.actions().first), row: harness.selectedRow, launch: .root)
        #expect(harness.fakes.usage.recorded.isEmpty)
    }

    @Test func stableIDsReadWellAndIgnoreHowAccentsAreStored() {
        let composed = Command.stableID("script", name: "Café Report", uniqueKey: "/tmp/scripts/cafe.sh")
        let decomposed = Command.stableID("script", name: "Cafe\u{301} Report", uniqueKey: "/tmp/scripts/cafe.sh")
        #expect(composed == decomposed)
        #expect(composed.hasPrefix("script.cafe-report-"))
        #expect(composed.count == "script.cafe-report-".count + 8)
        #expect(Command.stableID("script", name: "Café Report", uniqueKey: "/tmp/other/cafe.sh") != composed)
        #expect(Command.stableID("x", name: "🙂", uniqueKey: "k").count == "x.".count + 8)
    }

    @Test func templateArgumentsBecomeCommandArguments() {
        let template = Template(#"{argument name="lang" options="en, fr"} {argument name="q"} {argument default="1"}"#)
        let arguments = template.commandArguments
        #expect(arguments.map(\.name) == ["lang", "q", "#1"])
        #expect(arguments[0].kind == .dropdown([CommandArgument.Option("en"), CommandArgument.Option("fr")]))
        #expect(!arguments[1].isOptional)
        #expect(arguments[2].isOptional && arguments[2].defaultValue == "1")
    }
}
