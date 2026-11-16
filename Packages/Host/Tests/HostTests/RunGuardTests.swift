import AppKit
import Foundation
import Host
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import Testing

/// A feature with a command that must never see text a link chose, one that hands work to it, and
/// one with a dropdown argument whose value a script would trust.
final class Gatekeeper: Feature {
    static let manifest = FeatureManifest(id: "gatekeeper", name: "Gatekeeper", icon: .symbol("lock"))
    static let shell = ItemID.command(feature: "gatekeeper", command: "shell")
    static let handOff = ItemID.command(feature: "gatekeeper", command: "hand-off")
    static let clean = ItemID.command(feature: "gatekeeper", command: "clean")
    static let handOffBadChoice = ItemID.command(feature: "gatekeeper", command: "hand-off-bad")

    private(set) var shellRuns: [String] = []
    private(set) var cleaned: [String] = []

    init(context: FeatureContext) {}

    var commands: [Command] {
        [
            Command(id: "shell", title: "Run Shell Text", arguments: [CommandArgument("text")], allowsDeepLinks: false)
            {
                context in
                self.shellRuns.append(context.arguments["text"] ?? "")
                return .keepOpen
            }.withRowActions {
                [
                    Action("Run in Terminal", id: "terminal") { context in
                        self.shellRuns.append("terminal:" + context.query)
                        return .keepOpen
                    }
                ]
            },
            Command(id: "hand-off", title: "Hand Off to Shell") { _ in
                .run(Self.shell, arguments: ["text": "chosen by a page"])
            },
            Command(
                id: "clean", title: "Clean Cache",
                arguments: [
                    CommandArgument(
                        "cache", placeholder: "cache",
                        kind: .dropdown([.init("Images", value: "images"), .init("Logs", value: "logs")]))
                ]
            ) { context in
                self.cleaned.append(context.arguments["cache"] ?? "")
                return .keepOpen
            },
            Command(id: "hand-off-bad", title: "Hand Off a Bad Choice") { _ in
                .run(Self.clean, arguments: ["cache": "../Documents"])
            },
        ]
    }
}

/// A panel that shows a session a link opened, as far as the pipeline sees it: it records toasts
/// and answers every question yes.
@MainActor final class LinkSessionPresenter: RunPresenter {
    var isPanelVisible = true
    var sessionID = 1
    var linkSessions: Set<Int> = [1]
    private(set) var toasts: [Toast] = []

    func isLinkSession(_ session: Int) -> Bool { linkSessions.contains(session) }
    func showToast(_ toast: Toast, id: ToastID, origin: RunOrigin?) { toasts.append(toast) }
    func dismissToast(_ id: ToastID) {}
    func showHUD(_ hud: HUD) {}
    func confirm(_ confirmation: Kit.Confirmation, isDestructive: Bool) async -> Bool { true }
    func askForPermission(_ permission: Permission, featureName: String, reason: String) async -> Bool { true }
    func apply(_ outcome: ActionOutcome, origin: RunOrigin) {}
    func reloadTopPage() {}
    func setQuery(_ text: String) {}
    func quickLook(_ urls: [URL]) {}
    func share(_ items: [ShareItem]) {}
    func dismissPanel() { isPanelVisible = false }
}

/// What the pipeline refuses before a handler runs: a dropdown value outside its options, from any
/// launch, and a command that stays out of links, for a link, a hand-off a link's run made, or a
/// run in a panel session a link opened.
@Suite("Pipeline: guards", .serialized, .timeLimit(.minutes(1)))
@MainActor struct RunGuardTests {
    private func gatekeeper() async -> (RuntimeFixture, Gatekeeper) {
        let runtime = RuntimeFixture()
        await runtime.runtime.start([FeatureRegistration(Gatekeeper.self)])
        return (runtime, runtime.runtime.instance("gatekeeper") as! Gatekeeper)
    }

    // MARK: Dropdown values

    @Test(arguments: [LaunchSource.deeplink, .root, .page, .hotkey, .command, .textExpansion, .settings])
    func aDropdownValueOutsideItsOptionsIsRefused(launch: LaunchSource) async {
        let (runtime, feature) = await gatekeeper()
        await runtime.runtime.pipeline.runCommand(
            Gatekeeper.clean, arguments: ["cache": "../Documents"], launch: launch
        )
        .value
        #expect(feature.cleaned.isEmpty)
        #expect(runtime.presenter.toasts.map(\.title) == ["Not an Option for Cache"])
        #expect(runtime.presenter.toasts.first?.style == .failure)

        await runtime.runtime.pipeline.runCommand(Gatekeeper.clean, arguments: ["cache": "logs"], launch: launch).value
        #expect(feature.cleaned == ["logs"])
    }

    @Test func aHandOffWithAValueOutsideTheOptionsIsRefused() async {
        let (runtime, feature) = await gatekeeper()
        await runtime.runtime.pipeline.runCommand(Gatekeeper.handOffBadChoice, launch: .root).value
        #expect(feature.cleaned.isEmpty)
        #expect(runtime.presenter.toasts.map(\.title) == ["Not an Option for Cache"])
    }

    // MARK: Links

    @Test func aHandOffFromALinksRunToACommandThatRefusesLinksIsRefused() async {
        let (runtime, feature) = await gatekeeper()
        await runtime.runtime.pipeline.runCommand(Gatekeeper.handOff, launch: .deeplink).value
        #expect(feature.shellRuns.isEmpty)
        #expect(runtime.presenter.toasts.map(\.title) == ["This Command Cannot Run from a Link"])

        // The same hand-off from root search goes through.
        await runtime.runtime.pipeline.runCommand(Gatekeeper.handOff, launch: .root).value
        #expect(feature.shellRuns == ["chosen by a page"])
    }

    @Test func aRunInALinkSessionOfACommandThatRefusesLinksIsRefused() async throws {
        let (runtime, feature) = await gatekeeper()
        let presenter = LinkSessionPresenter()
        let pipeline = runtime.runtime.pipeline
        pipeline.presenter = presenter
        await pipeline.runCommand(Gatekeeper.shell, arguments: ["text": "typed by a link"], launch: .root).value
        await pipeline.runCommand(Gatekeeper.shell, typedText: "typed by a link", launch: .fallback).value
        await pipeline.runCommand(Gatekeeper.shell, typedText: "typed by a link", launch: .tabFromRoot).value
        let row = Row(id: Gatekeeper.shell, title: "Run Shell Text")
        if let rowAction = runtime.runtime.command(Gatekeeper.shell)?.command.rowActions?().first {
            await pipeline.perform(
                rowAction, featureID: "gatekeeper", context: runtime.runtime.context(for: "gatekeeper"),
                query: "typed by a link", launch: .root, row: row
            ).value
        }
        #expect(feature.shellRuns.isEmpty)
        #expect(presenter.toasts.count == 4)
        #expect(presenter.toasts.allSatisfy { $0.title == "This Command Cannot Run from a Link" })
        #expect(presenter.toasts.first?.message?.contains("Open it yourself") == true)

        // The next session, which the user opened, runs it.
        presenter.sessionID += 1
        await pipeline.runCommand(Gatekeeper.shell, arguments: ["text": "typed by the user"], launch: .root).value
        #expect(feature.shellRuns == ["typed by the user"])
    }

    @Test func aCommandThatAllowsLinksStillRunsInALinkSession() async {
        let (runtime, feature) = await gatekeeper()
        let presenter = LinkSessionPresenter()
        runtime.runtime.pipeline.presenter = presenter
        await runtime.runtime.pipeline.runCommand(Gatekeeper.clean, arguments: ["cache": "logs"], launch: .root).value
        #expect(feature.cleaned == ["logs"])
        #expect(presenter.toasts.isEmpty)
    }

    @Test func aRootRowRunAfterALinksTextIsRefusedOnThePanel() async {
        let fixture = await PanelFixture.make(
            rows: [Row(id: RuntimeFixture.command("act-now"), title: "Act Now")], summon: false)
        defer { fixture.close() }
        let panel = fixture.panel
        panel.showRootForLink(query: "act")
        fixture.press(.moveDown)
        fixture.press(.submit([]))
        #expect(await waitUntil { panel.surface.actionBar.toast != nil })
        #expect(panel.surface.actionBar.toast?.text.hasPrefix("This Command Cannot Run from a Link") == true)
        #expect(!fixture.runtime.workbench.log.contains("act-now"))

        // Opened by the user, the panel runs it.
        panel.dismiss()
        panel.summon()
        fixture.type("act")
        fixture.press(.submit([]))
        #expect(await waitUntil { fixture.runtime.workbench.log.contains("act-now") })
    }
}
