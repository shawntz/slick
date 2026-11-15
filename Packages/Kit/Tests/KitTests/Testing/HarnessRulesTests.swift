import Foundation
import Kit
import KitTesting
import Testing

/// The host rules added for features: feedback after the panel closes, run policies, permission
/// requests from handlers, handoffs to unavailable commands, errors, and the outcomes that leave root.
@Suite("FeatureHarness: host rules")
struct HarnessRulesTests {
    final class Probe: Feature {
        static let manifest = FeatureManifest(
            id: "probe", name: "Probe", icon: .glyph("P"),
            permissions: [PermissionNeed(.automation(bundleID: "com.example.app"), reason: "Script the example app.")])
        static let other = ItemID.command(feature: "other", command: "go")
        var presses: [Int] = []

        init(context: FeatureContext) {}

        var commands: [Command] {
            [
                Command(id: "silent", title: "Silent") { context in
                    context.dismiss()
                    let progress = context.showToast(.progress("Working"))
                    progress.update(.success("Done"))
                    return .close()
                },
                Command(id: "slow", title: "Slow") { context in
                    // Reads, waits, then writes, as cycling a window's size does.
                    let count = self.presses.count
                    try await context.clock.sleep(for: .seconds(1))
                    self.presses.append(count)
                    return .keepOpen
                },
                Command(id: "once", title: "Once", runPolicy: .dropWhileRunning) { context in
                    try await context.clock.sleep(for: .seconds(1))
                    return .keepOpen
                },
                Command(id: "automate", title: "Automate") { context in
                    guard context.permissions.isGranted(.automation(bundleID: "com.example.app")) else {
                        return .needsPermission(.automation(bundleID: "com.example.app"))
                    }
                    return .close(hud: "Automated")
                },
                Command(id: "fail", title: "Fail") { _ in throw ActionFailure("Could not reach the server") },
                Command(id: "hand-off", title: "Hand Off") { _ in .run(Self.other, arguments: ["text": "long"]) },
                Command(id: "again", title: "Again") { _ in .showRoot(query: "12 * 3") },
                Command(
                    id: "clear", title: "Clear",
                    confirmation: Confirmation("Clear everything?", confirmTitle: "Clear", isDestructive: true)
                ) { _ in .close(hud: "Cleared") },
            ]
        }

        var actions: [Action] {
            [
                Action("Do", id: "do") { _ in .keepOpen },
                .runCommand(Self.other, title: "Send Elsewhere"),
                Action("Modifier", id: "mod", shortcut: KeyCombo(.return, .option)) { _ in .keepOpen },
            ]
        }
    }

    @Test func aToastAfterDismissIsAHUDAndCanBeUpdated() async throws {
        let harness = FeatureHarness(Probe.self)
        try await harness.run("silent")
        #expect(harness.huds == [HUD("Working", style: .progress), .success("Done")])
        #expect(harness.toasts.isEmpty)
        #expect(harness.isClosed)
    }

    @Test func aHotkeyRunShowsToastsAsHUDs() async throws {
        let harness = FeatureHarness(Probe.self)
        harness.throwsActionErrors = false
        try await harness.run("fail", launch: .hotkey)
        #expect(harness.huds == [.failure("Could not reach the server")])
        try await harness.run("fail")
        #expect(harness.toasts.map(\.title) == ["Could not reach the server"])
        #expect(harness.actionErrors.count == 2)
    }

    @Test func thrownErrorsReachTheTestByDefault() async {
        let harness = FeatureHarness(Probe.self)
        await #expect(throws: ActionFailure("Could not reach the server")) { try await harness.run("fail") }
    }

    @Test func serialRunsSeeTheEarlierRunsResult() async throws {
        let harness = FeatureHarness(Probe.self)
        let clock = harness.fakes.clock
        async let first: ActionOutcome = harness.run("slow")
        async let second: ActionOutcome = harness.run("slow")
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(1))
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(1))
        _ = try await (first, second)
        #expect(harness.feature.presses == [0, 1], "the second run read after the first wrote")
    }

    @Test func dropWhileRunningIgnoresASecondStart() async throws {
        let harness = FeatureHarness(Probe.self)
        async let first: ActionOutcome = harness.run("once")
        await harness.fakes.clock.waitForSleepers(1)
        let second = try await harness.run("once")
        harness.fakes.clock.advance(by: .seconds(1))
        _ = try await first
        #expect(second.kind == .keepOpen)
        #expect(harness.droppedRuns == ["command.once"])
    }

    @Test func aPermissionFoundMissingRunsTheGrantFlowThenRunsAgain() async throws {
        let harness = FeatureHarness(Probe.self)
        let automation = Permission.automation(bundleID: "com.example.app")
        harness.fakes.permissions.set(automation, to: .notDetermined)
        await #expect(throws: HarnessError.permissionRequired([automation])) { try await harness.run("automate") }
        #expect(harness.fakes.permissions.requests.isEmpty)
        harness.grantsMissingPermissions = true
        try await harness.run("automate")
        #expect(harness.fakes.permissions.requests == [automation])
        #expect(harness.huds == ["Automated"])
    }

    @Test func actionsForAnUnavailableCommandAreHidden() async throws {
        let harness = FeatureHarness(Probe.self)
        let page = ListPage(sections: [ListSection(rows: [Row(id: ItemID("probe", "1"), title: "One")])]) { _ in
            harness.feature.actions
        }
        try await harness.open(.list(page))
        #expect(harness.actions().map(\.title) == ["Do", "Send Elsewhere", "Modifier"])
        harness.unavailableCommands = [Probe.other]
        #expect(harness.actions().map(\.title) == ["Do", "Modifier"])
        try await harness.run("hand-off")
        #expect(harness.commandRuns == [CommandRun(id: Probe.other, arguments: ["text": "long"])])
        #expect(harness.toasts.map(\.style) == [.failure])
    }

    @Test func commandReturnRunsTheDeclaredOrTheSecondActionWithoutAShortcut() {
        let actions = FeatureHarness(Probe.self).feature.actions
        #expect(actions.primary?.id == "do")
        #expect(actions.secondary?.title == "Send Elsewhere")
        #expect([actions[0], actions[2]].secondary == nil, "an Option-Return action is not Command-Return")
        let declared = [actions[0], actions[1], actions[2].with(shortcut: .secondaryAction)]
        #expect(declared.secondary?.id == "mod")
    }

    @Test func showRootLeavesThePagesWithAQuery() async throws {
        let harness = FeatureHarness(Probe.self)
        let outcome = try await harness.run("again")
        #expect(outcome.kind == .showRoot(query: "12 * 3"))
        #expect(harness.rootQueries == ["12 * 3"])
        #expect(harness.pages.isEmpty)
    }

    @Test func aCommandConfirmationIsAskedFirst() async throws {
        let harness = FeatureHarness(Probe.self)
        harness.confirmationAnswer = false
        #expect(try await harness.run("clear").kind == .keepOpen)
        #expect(harness.huds.isEmpty)
        harness.confirmationAnswer = true
        try await harness.run("clear")
        #expect(harness.huds == ["Cleared"])
        #expect(harness.confirmations.map(\.title) == ["Clear everything?", "Clear everything?"])
    }
}
