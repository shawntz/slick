import AppKit
import Foundation
import Host
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import Testing

/// A feature shaped like Shell Commands. Root search shows a row with the text the user typed, and
/// its Return hands that text to the feature's own command through `.run`, with a token only this
/// instance knows. The command stays out of links. It acts only on its own hand-off, and puts any
/// other text back in root search behind the prefix, where the user reads it.
final class ShellShaped: Feature {
    static let manifest = FeatureManifest(id: "shellshaped", name: "Shell Shaped", icon: .symbol("terminal"))
    static let run = ItemID.command(feature: "shellshaped", command: "run")
    static let namespace = "shellshaped"

    private let token = UUID().uuidString
    private(set) var runs: [String] = []
    private(set) var putBack: [String] = []

    init(context: FeatureContext) {}

    var commands: [Command] {
        [
            Command(
                id: "run", title: "Run Shaped Command", arguments: [CommandArgument("command")],
                allowsDeepLinks: false
            ) { context in
                let text = context.arguments["command"] ?? ""
                guard context.launch == .command, context.arguments["token"] == self.token else {
                    self.putBack.append(text)
                    return .showRoot(query: "> " + text)
                }
                self.runs.append(text)
                return .keepOpen
            }
        ]
    }

    /// The typed row's Return.
    func handOff(_ text: String) -> Action {
        Action("Run in Shell", id: "run-typed") { [token] _ in
            .run(Self.run, arguments: ["command": text, "token": token])
        }
    }

    /// The row root search shows for `> text`.
    static func row(_ text: String) -> Row {
        Row(id: ItemID(namespace, "typed"), title: "> " + text, subtitle: "Press Return to run it", memory: .never)
    }
}

/// The host's refusal of a command that stays out of links, for the shape Shell Commands uses: a
/// row that is not a command, whose action hands text to the feature's own command. And text that a
/// link or an outcome puts in the search field runs nothing until the user presses Return on the
/// row that shows it.
@Suite("Pipeline: a typed row's hand-off", .serialized, .timeLimit(.minutes(1)))
@MainActor struct TypedRowHandOffTests {
    private func shellShaped() async -> (RuntimeFixture, ShellShaped) {
        let runtime = RuntimeFixture()
        await runtime.runtime.start([FeatureRegistration(ShellShaped.self)])
        return (runtime, runtime.runtime.instance("shellshaped") as! ShellShaped)
    }

    private func pressReturn(
        on text: String, _ runtime: RuntimeFixture, _ feature: ShellShaped, action: Action? = nil
    ) async {
        await runtime.runtime.pipeline.perform(
            action ?? feature.handOff(text), featureID: "shellshaped",
            context: runtime.runtime.context(for: "shellshaped"), query: "> " + text, launch: .root,
            row: ShellShaped.row(text)
        ).value
    }

    @Test func theRowsHandOffRunsInASessionTheUserOpened() async {
        let (runtime, feature) = await shellShaped()
        let presenter = LinkSessionPresenter()
        presenter.linkSessions = []
        runtime.runtime.pipeline.presenter = presenter
        await pressReturn(on: "echo hi", runtime, feature)
        #expect(feature.runs == ["echo hi"])
        #expect(presenter.toasts.isEmpty)
    }

    @Test func theRowsHandOffIsRefusedInASessionALinkOpened() async {
        let (runtime, feature) = await shellShaped()
        let presenter = LinkSessionPresenter()
        runtime.runtime.pipeline.presenter = presenter
        await pressReturn(on: "echo hi", runtime, feature)
        #expect(feature.runs.isEmpty)
        #expect(feature.putBack.isEmpty, "the command's handler never ran")
        #expect(presenter.toasts.map(\.title) == ["This Command Cannot Run from a Link"])

        // The next session, which the user opened, runs it.
        presenter.sessionID += 1
        await pressReturn(on: "echo hi", runtime, feature)
        #expect(feature.runs == ["echo hi"])
    }

    /// A link that arrives while the row's action runs puts its page over the user's, and the
    /// session becomes a link session. The hand-off that follows is refused.
    @Test func aHandOffIsRefusedWhenALinkTookThePanelWhileTheRowRan() async {
        let (runtime, feature) = await shellShaped()
        let presenter = LinkSessionPresenter()
        presenter.linkSessions = []
        runtime.runtime.pipeline.presenter = presenter
        let handOff = feature.handOff("echo hi")
        guard case .run(let handler) = handOff.kind else {
            Issue.record("the hand-off runs")
            return
        }
        let racing = Action("Run in Shell", id: "run-typed") { context in
            presenter.linkSessions = [presenter.sessionID]
            return try await handler(context)
        }
        await pressReturn(on: "echo hi", runtime, feature, action: racing)
        #expect(feature.runs.isEmpty)
        #expect(presenter.toasts.map(\.title) == ["This Command Cannot Run from a Link"])
    }

    @Test func aHandOffFromALinksRunIsRefusedAfterThePanelClosed() async {
        let (runtime, feature) = await shellShaped()
        let presenter = LinkSessionPresenter()
        runtime.runtime.pipeline.presenter = presenter
        guard case .run(let handler) = feature.handOff("echo hi").kind else {
            Issue.record("the hand-off runs")
            return
        }
        let closing = Action("Run in Shell", id: "run-typed") { context in
            context.dismiss()
            return try await handler(context)
        }
        await pressReturn(on: "echo hi", runtime, feature, action: closing)
        #expect(!presenter.isPanelVisible)
        #expect(feature.runs.isEmpty)
        #expect(feature.putBack.isEmpty)
    }

    /// Another feature's hand-off, a fallback, Tab and every other launch reach the command without
    /// the token, so it only puts the text back where the user reads it.
    @Test func everyOtherWayInOnlyPutsTheTextBack() async {
        let (runtime, feature) = await shellShaped()
        let presenter = LinkSessionPresenter()
        presenter.linkSessions = []
        runtime.runtime.pipeline.presenter = presenter
        let pipeline = runtime.runtime.pipeline
        for launch: LaunchSource in [.fallback, .tabFromRoot, .suggestion, .selection, .textExpansion, .settings] {
            await pipeline.runCommand(ShellShaped.run, typedText: "rm example", launch: launch).value
        }
        let foreign = Action("Hand Off", id: "foreign") { _ in
            .run(ShellShaped.run, arguments: ["command": "rm example", "token": "guessed"])
        }
        await pipeline.perform(
            foreign, featureID: "workbench", context: runtime.runtime.context(for: "shellshaped"), query: "",
            launch: .root, row: nil
        ).value
        #expect(feature.runs.isEmpty)
        #expect(feature.putBack.count == 7)
    }

    // MARK: On the panel

    private func panel(text: String) async -> (PanelFixture, ShellShaped) {
        let fixture = await PanelFixture.make(
            rows: [ShellShaped.row(text)], summon: false, features: [FeatureRegistration(ShellShaped.self)])
        let feature = fixture.runtime.runtime.instance("shellshaped") as! ShellShaped
        fixture.root.featureIDs[ShellShaped.namespace] = "shellshaped"
        fixture.root.rowActions = { row in
            row.id.namespace == ShellShaped.namespace ? [feature.handOff(text)] : []
        }
        return (fixture, feature)
    }

    /// The root rows the panel ran, which it tells root search at once, before the run starts.
    private func ranRows(_ fixture: PanelFixture) -> [ItemID] {
        fixture.root.calls.compactMap { call in
            if case .didRun(let id, _) = call { return id }
            return nil
        }
    }

    @Test func textALinkTypesSelectsNoRowAndTheRowIsRefusedInThatSession() async {
        let (fixture, feature) = await panel(text: "echo hi")
        defer { fixture.close() }
        let panel = fixture.panel
        panel.showRootForLink(query: "> echo hi")
        #expect(fixture.rootTitles == ["> echo hi"])
        fixture.press(.submit([]))
        fixture.press(.chord(KeyChord("1", .command)))
        #expect(ranRows(fixture).isEmpty, "Return and Command-1 run nothing a link chose")

        fixture.press(.moveDown)
        fixture.press(.submit([]))
        #expect(await waitUntil { panel.surface.actionBar.toast != nil })
        #expect(panel.surface.actionBar.toast?.text.hasPrefix("This Command Cannot Run from a Link") == true)
        #expect(feature.runs.isEmpty)

        // Opened by the user, the panel runs the row the user pressed Return on.
        panel.dismiss()
        panel.summon()
        fixture.type("> echo hi")
        fixture.press(.submit([]))
        #expect(await waitUntil { feature.runs == ["echo hi"] })
    }

    @Test func textAnOutcomeOrTabPutsInTheFieldRunsNothingUntilReturn() async {
        let (fixture, feature) = await panel(text: "echo hi")
        defer { fixture.close() }
        let panel = fixture.panel
        panel.summon()

        // Another feature hands the text over, as a fallback or a suggestion would: it lands in
        // the field and nothing runs.
        await fixture.runtime.runtime.pipeline.runCommand(ShellShaped.run, typedText: "echo hi", launch: .fallback)
            .value
        #expect(await waitUntil { fixture.field.text == "> echo hi" })
        #expect(feature.runs.isEmpty)

        // Tab puts a row's completion in the field, and runs nothing.
        fixture.root.rows.append(Row(id: ItemID("other", "completion"), title: "Completes", completion: "> echo hi"))
        fixture.type("Completes")
        fixture.press(.complete)
        #expect(fixture.field.text == "> echo hi")
        #expect(ranRows(fixture).isEmpty)
        #expect(feature.runs.isEmpty)

        // Return on the row that shows the command runs it.
        fixture.type("> echo hi")
        fixture.press(.submit([]))
        #expect(await waitUntil { feature.runs == ["echo hi"] })
    }
}
