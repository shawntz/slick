import Foundation
import Host
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Testing

/// The one pipeline every command and action runs through.
@Suite("Runtime: pipeline", .timeLimit(.minutes(1)))
@MainActor struct PipelineTests {
    private func started() async -> RuntimeFixture {
        let fixture = RuntimeFixture()
        await fixture.start()
        return fixture
    }

    @Test func thrownErrorsAreFailureToastsOrHUDs() async {
        let fixture = await started()
        let pipeline = fixture.runtime.pipeline
        await pipeline.runCommand(RuntimeFixture.command("fail"), launch: .root).value
        #expect(fixture.presenter.toasts.map(\.title) == ["Could not reach the server"])
        #expect(fixture.presenter.toasts.first?.message == "Timed out")
        #expect(fixture.presenter.toasts.first?.style == .failure)
        fixture.presenter.isPanelVisible = false
        await pipeline.runCommand(RuntimeFixture.command("fail"), launch: .hotkey).value
        #expect(fixture.presenter.huds == [.failure("Could not reach the server")])
        await pipeline.runCommand(RuntimeFixture.command("cancelled"), launch: .root).value
        #expect(fixture.presenter.toasts.count == 1 && fixture.presenter.huds.count == 1, "cancellation shows nothing")
    }

    @Test func serialRunsSeeTheEarlierRunsResult() async {
        let fixture = await started()
        let clock = fixture.fakes.clock
        let first = fixture.runtime.pipeline.runCommand(RuntimeFixture.command("slow"), launch: .root)
        let second = fixture.runtime.pipeline.runCommand(RuntimeFixture.command("slow"), launch: .root)
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(1))
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(1))
        await first.value
        await second.value
        #expect(fixture.workbench.presses == [0, 1], "the second run read after the first wrote")
    }

    @Test func dropWhileRunningIgnoresASecondStart() async {
        let fixture = await started()
        let first = fixture.runtime.pipeline.runCommand(RuntimeFixture.command("once"), launch: .root)
        await fixture.fakes.clock.waitForSleepers(1)
        await fixture.runtime.pipeline.runCommand(RuntimeFixture.command("once"), launch: .root).value
        fixture.fakes.clock.advance(by: .seconds(1))
        await first.value
        #expect(fixture.runtime.pipeline.droppedRuns == ["workbench/command.once"])
    }

    @Test func closingThePanelDoesNotCancelAHandler() async {
        let fixture = await started()
        let run = fixture.runtime.pipeline.runCommand(RuntimeFixture.command("wait"), launch: .root)
        await fixture.fakes.clock.waitForSleepers(1)
        fixture.presenter.dismissPanel()
        fixture.fakes.clock.advance(by: .seconds(600))
        await run.value
        #expect(fixture.workbench.log == ["wait started", "wait finished"])
    }

    @Test func aMissingPermissionShowsTheCardThenRuns() async {
        let fixture = await started()
        fixture.fakes.permissions.set(.accessibility, to: .notDetermined)
        fixture.presenter.permissionAnswer = false
        await fixture.runtime.pipeline.runCommand(RuntimeFixture.command("guarded"), launch: .root).value
        #expect(fixture.workbench.log.isEmpty)
        #expect(fixture.fakes.permissions.requests.isEmpty, "nothing asks the system before the user pressed Grant")
        #expect(fixture.presenter.permissionCards.first?.reason == "Move the windows you pick.")
        #expect(fixture.presenter.permissionCards.first?.feature == "Workbench")

        fixture.presenter.permissionAnswer = true
        await fixture.runtime.pipeline.runCommand(RuntimeFixture.command("guarded"), launch: .root).value
        #expect(fixture.fakes.permissions.requests == [.accessibility])
        #expect(fixture.workbench.log == ["guarded"])
    }

    @Test func aPermissionFoundMissingRunsTheHandlerAgainAfterAGrant() async {
        let fixture = await started()
        fixture.fakes.permissions.set(.accessibility, to: .denied)
        await fixture.runtime.pipeline.runCommand(RuntimeFixture.command("automate"), launch: .root).value
        #expect(fixture.presenter.permissionCards.count == 1)
        #expect(fixture.workbench.log == ["automate"])
    }

    /// Asked before, the system shows nothing, so Host opens the pane. A grant there ends the run
    /// without running it: the app in front may be System Settings.
    @Test func aGrantInSettingsOpensThePaneAndAsksToRunAgainInsteadOfRunning() async {
        let fixture = await started()
        let pipeline = fixture.runtime.pipeline
        fixture.fakes.permissions.set(.accessibility, to: .denied)
        fixture.fakes.permissions.answer = .denied
        let run = pipeline.runCommand(RuntimeFixture.command("guarded"), launch: .root)
        #expect(await waitUntil { pipeline.grantWaitCount == 1 })
        #expect(fixture.workbench.log.isEmpty)
        #expect(fixture.fakes.permissions.openedSettings == [.accessibility])
        #expect(fixture.presenter.dismissals == 1, "System Settings would close the panel with its toast unread")
        #expect(fixture.presenter.huds == [.failure("Allow Accessibility in System Settings")])
        #expect(pipeline.activeRunCount == 0, "a run waiting in System Settings is not busy")

        fixture.fakes.permissions.set(.accessibility, to: .granted)
        await run.value
        #expect(fixture.workbench.log.isEmpty, "a paste now would land in System Settings")
        #expect(fixture.presenter.huds.last == .success("Accessibility Allowed, Run Guarded Again"))
        #expect(fixture.workbench.grants == [.accessibility], "the feature hears of the grant")
        #expect(pipeline.grantWaitCount == 0)

        await pipeline.runCommand(RuntimeFixture.command("guarded"), launch: .root).value
        #expect(fixture.workbench.log == ["guarded"], "run again, it runs")
    }

    /// The first ask of Accessibility shows the system's own dialog, which offers System Settings
    /// itself. Host opens no pane beside it, and still waits for the grant.
    @Test func theSystemsOwnDialogIsNotDoubledByThePane() async {
        let fixture = await started()
        let pipeline = fixture.runtime.pipeline
        fixture.fakes.permissions.set(.accessibility, to: .notDetermined)
        fixture.fakes.permissions.answer = .denied
        let run = pipeline.runCommand(RuntimeFixture.command("guarded"), launch: .root)
        #expect(await waitUntil { pipeline.grantWaitCount == 1 })
        #expect(fixture.fakes.permissions.requests == [.accessibility])
        #expect(fixture.fakes.permissions.openedSettings.isEmpty)
        #expect(fixture.presenter.huds == [.failure("Allow Accessibility in System Settings")])
        fixture.fakes.permissions.set(.accessibility, to: .granted)
        await run.value
        #expect(fixture.workbench.log.isEmpty)
        #expect(fixture.presenter.huds.last == .success("Accessibility Allowed, Run Guarded Again"))
    }

    @Test func aGrantOnTheCardRunsAtOnceAndTellsTheFeature() async {
        let fixture = await started()
        let pipeline = fixture.runtime.pipeline
        fixture.fakes.permissions.set(.accessibility, to: .notDetermined)
        fixture.fakes.permissions.answer = .granted
        await pipeline.runCommand(RuntimeFixture.command("guarded"), launch: .root).value
        #expect(fixture.workbench.log == ["guarded"])
        #expect(fixture.workbench.grants == [.accessibility])
        #expect(fixture.fakes.permissions.openedSettings.isEmpty)
        #expect(fixture.presenter.huds.isEmpty)
    }

    @Test(arguments: [
        (Permission.accessibility, PermissionStatus.notDetermined, PermissionStatus.denied, true),
        (.inputMonitoring, .notDetermined, .notDetermined, true),
        (.screenRecording, .notDetermined, .denied, true),
        (.accessibility, .denied, .denied, false),
        (.inputMonitoring, .denied, .denied, false),
        (.calendars, .notDetermined, .denied, true),
        (.calendars, .denied, .denied, false),
        (.automation(bundleID: "com.example.missing"), .notDetermined, .notDetermined, false),
        (.fullDiskAccess, .notDetermined, .notDetermined, false),
        (.pasteboard, .notDetermined, .denied, false),
    ])
    func theSystemAskedItselfOnlyOnTheFirstAskOfAPermissionWithADialog(
        permission: Permission, before: PermissionStatus, after: PermissionStatus, asked: Bool
    ) {
        #expect(RunPipeline.systemAskedItself(permission, before: before, after: after) == asked)
    }

    @Test func aGrantThatNeverComesEndsTheWait() async {
        let fixture = await started()
        let pipeline = fixture.runtime.pipeline
        fixture.fakes.permissions.set(.accessibility, to: .notDetermined)
        fixture.fakes.permissions.answer = .denied
        let run = pipeline.runCommand(RuntimeFixture.command("guarded"), launch: .root)
        #expect(await waitUntil { pipeline.grantWaitCount == 1 })
        await fixture.fakes.clock.waitForSleepers(1)
        fixture.fakes.clock.advance(by: RunPipeline.grantWait)
        await run.value
        #expect(fixture.workbench.log.isEmpty)
        #expect(pipeline.grantWaitCount == 0)
        fixture.fakes.permissions.set(.accessibility, to: .granted)
        await fixture.fakes.permissions.settle()
        #expect(fixture.workbench.log.isEmpty, "a grant after the wait ended runs nothing")
    }

    @Test func aNewerWaitForTheSamePermissionReplacesTheOlder() async {
        let fixture = await started()
        let pipeline = fixture.runtime.pipeline
        fixture.fakes.permissions.set(.accessibility, to: .denied)
        fixture.fakes.permissions.answer = .denied
        let first = pipeline.runCommand(RuntimeFixture.command("guarded"), launch: .root)
        #expect(await waitUntil { pipeline.grantWaitCount == 1 })
        let second = pipeline.runCommand(RuntimeFixture.command("guarded"), launch: .root)
        await first.value
        #expect(await waitUntil { pipeline.grantWaitCount == 1 })
        fixture.fakes.permissions.set(.accessibility, to: .granted)
        await second.value
        #expect(fixture.workbench.log.isEmpty)
        let asked = fixture.presenter.huds.filter { $0 == .success("Accessibility Allowed, Run Guarded Again") }
        #expect(asked.count == 1, "one grant asks once")
        #expect(fixture.workbench.grants == [.accessibility])
    }

    @Test func aConfirmationIsAskedAndCanBeSuppressed() async {
        let fixture = await started()
        let pipeline = fixture.runtime.pipeline
        fixture.presenter.confirmAnswer = false
        await pipeline.runCommand(RuntimeFixture.command("clear"), launch: .root).value
        #expect(fixture.workbench.log.isEmpty)
        fixture.presenter.confirmAnswer = true
        await pipeline.runCommand(RuntimeFixture.command("clear"), launch: .root).value
        #expect(fixture.workbench.log == ["clear"])
        fixture.runtime.preferences.setConfirmationSuppressed(true, key: "workbench.clear")
        fixture.presenter.confirmAnswer = false
        await pipeline.runCommand(RuntimeFixture.command("clear"), launch: .root).value
        #expect(fixture.workbench.log == ["clear", "clear"], "a suppressed confirmation is not asked")
        #expect(fixture.presenter.confirmations.map(\.title) == ["Clear everything?", "Clear everything?"])
    }

    /// A feature's own question honors "Don't ask again" as a declared confirmation does.
    @Test func aFeaturesOwnConfirmationCanBeSuppressed() async {
        let fixture = await started()
        let pipeline = fixture.runtime.pipeline
        fixture.presenter.confirmAnswer = false
        await pipeline.runCommand(RuntimeFixture.command("eject"), launch: .root).value
        #expect(fixture.workbench.log.isEmpty)
        fixture.runtime.preferences.setConfirmationSuppressed(true, key: "workbench.eject-all")
        await pipeline.runCommand(RuntimeFixture.command("eject"), launch: .root).value
        #expect(fixture.workbench.log == ["eject"], "a suppressed question answers yes")
        #expect(fixture.presenter.confirmations.map(\.title) == ["Eject 2 disks?"])
    }

    @Test func runHandsOverWithUndeclaredArguments() async {
        let fixture = await started()
        await fixture.runtime.pipeline.runCommand(RuntimeFixture.command("hand-off"), launch: .root).value
        #expect(fixture.relay.received == [CommandArguments(["text": "long", "extra": "kept"])])
        #expect(fixture.relay.launches == [.command])
    }

    @Test func runToAnUnknownCommandShowsAFailureToast() async {
        let fixture = await started()
        await fixture.runtime.pipeline.runCommand(RuntimeFixture.command("nowhere"), launch: .root).value
        #expect(fixture.presenter.toasts.map(\.title) == ["This Command Is Not Available"])
    }

    /// A failure title is in title case even when it quotes a feature's placeholder.
    @Test func aMissingArgumentsTitleIsInTitleCase() async {
        let fixture = await started()
        fixture.runtime.register([FeatureRegistration(Lookup.self)])
        await fixture.runtime.pipeline.runCommand(.command(feature: "lookup", command: "find"), launch: .root).value
        #expect(fixture.presenter.toasts.map(\.title) == ["Enter a Word to Look Up First"])
    }

    @Test func argumentsGetDefaultsAndMissingOnesStopTheRun() async {
        let fixture = await started()
        let echo = RuntimeFixture.command("echo")
        await fixture.runtime.pipeline.runCommand(echo, launch: .root).value
        #expect(fixture.workbench.log.isEmpty)
        #expect(fixture.presenter.toasts.map(\.title) == ["Enter Text First"])
        await fixture.runtime.pipeline.runCommand(echo, typedText: "hello", launch: .fallback).value
        #expect(fixture.workbench.arguments == [CommandArguments(["text": "hello", "mode": "plain"])])
        #expect(fixture.workbench.queries == ["hello"])
        #expect(fixture.workbench.launches == [.fallback])
    }

    @Test func outcomesThatChangeThePanelGoToThePresenter() async {
        let fixture = await started()
        let pipeline = fixture.runtime.pipeline
        await pipeline.runCommand(RuntimeFixture.command("open-shelf"), launch: .root).value
        await pipeline.runCommand(RuntimeFixture.command("again"), launch: .root).value
        await pipeline.runCommand(RuntimeFixture.command("plain"), launch: .root).value
        #expect(fixture.presenter.outcomes == ["push", "showRoot:12 * 3", "close"])
        #expect(fixture.presenter.huds == ["Done"])
    }

    @Test func aReloadRequestReloadsOnceAfterTheOutcome() async {
        let fixture = await started()
        await fixture.runtime.pipeline.runCommand(RuntimeFixture.command("reloading"), launch: .page).value
        #expect(fixture.presenter.reloads == 1)
    }

    @Test func aToastButtonRunsWithTheContextOfItsRun() async throws {
        let fixture = await started()
        await fixture.runtime.pipeline.runCommand(RuntimeFixture.command("toast"), launch: .page).value
        let toast = try #require(fixture.presenter.toasts.first)
        let origin = try #require(fixture.presenter.toastOrigins.first ?? nil)
        #expect(origin.featureID == "workbench")
        let button = try #require(toast.action)
        await fixture.runtime.pipeline.perform(button, origin: origin).value
        #expect(fixture.workbench.log == ["undo"])
        #expect(fixture.workbench.launches == [.page])
    }

    @Test func actionsForAnUnavailableCommandAreHidden() async throws {
        let fixture = await started()
        let rowActions = try #require(fixture.runtime.command(RuntimeFixture.command("echo"))?.command.rowActions)
        #expect(fixture.runtime.visible(rowActions()).map(\.id) == ["edit", "run.cmd:relay.receive"])
        await fixture.runtime.preferences.setEnabled(false, feature: "relay")
        #expect(fixture.runtime.visible(rowActions()).map(\.id) == ["edit"])
    }
}

/// A feature whose one command needs a word, with a placeholder of several words.
final class Lookup: Feature {
    static let manifest = FeatureManifest(id: "lookup", name: "Lookup", icon: .glyph("L"))

    init(context: FeatureContext) {}

    var commands: [Command] {
        [
            Command(
                id: "find", title: "Find", arguments: [CommandArgument("word", placeholder: "a word to look up")]
            ) { _ in .keepOpen }
        ]
    }
}
