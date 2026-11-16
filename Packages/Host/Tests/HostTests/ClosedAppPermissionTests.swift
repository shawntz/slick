import Foundation
import Host
import Kit
import KitHosting
import KitTesting
import Testing

/// A feature shaped like Media Controls: its command finds Automation for a player missing and asks
/// the host for it.
final class PlayerShaped: Feature {
    static let player = Permission.automation(bundleID: "com.example.player")
    static let manifest = FeatureManifest(
        id: "playershaped", name: "Player Shaped", icon: .symbol("play"),
        permissions: [PermissionNeed(player, reason: "Play and pause in Example Player.")])
    static let play = ItemID.command(feature: "playershaped", command: "play")

    private(set) var plays = 0

    init(context: FeatureContext) {}

    var commands: [Command] {
        [
            Command(id: "play", title: "Play") { context in
                guard context.permissions.isGranted(Self.player) else { return .needsPermission(Self.player) }
                self.plays += 1
                return .keepOpen
            }
        ]
    }
}

/// The permission card for Automation of an app that is not open. Platform starts no app to ask,
/// so the request answers nothing; the host says the app is not open instead of sending the user
/// to System Settings, which does not list the app yet.
@Suite("Pipeline: Automation of an app that is not open", .serialized, .timeLimit(.minutes(1)))
@MainActor struct ClosedAppPermissionTests {
    private func started() async -> (RuntimeFixture, PlayerShaped) {
        let fixture = RuntimeFixture()
        await fixture.runtime.start([FeatureRegistration(PlayerShaped.self)])
        fixture.fakes.permissions.set(PlayerShaped.player, to: .notDetermined)
        fixture.fakes.workspace.installed = [AppInfo(bundleID: "com.example.player", name: "Example Player")]
        return (fixture, fixture.runtime.instance("playershaped") as! PlayerShaped)
    }

    @Test func theCardSaysTheAppIsNotOpenAndOpensNothing() async {
        let (fixture, feature) = await started()
        let pipeline = fixture.runtime.pipeline
        // The request asked nothing: the player is not running and nothing may start it.
        fixture.fakes.permissions.answer = .notDetermined
        let run = pipeline.runCommand(PlayerShaped.play, launch: .root)
        #expect(await waitUntil { !fixture.presenter.toasts.isEmpty || pipeline.grantWaitCount > 0 })
        #expect(fixture.presenter.permissionCards.map(\.permission) == [PlayerShaped.player])
        #expect(fixture.fakes.permissions.requests == [PlayerShaped.player])
        #expect(fixture.presenter.toasts.map(\.title) == ["Example Player Is Not Open"])
        #expect(
            fixture.presenter.toasts.first?.message
                == "macOS asks the first time you control Example Player while it is open. Open it, then run the "
                + "command again.")
        #expect(fixture.fakes.permissions.openedSettings.isEmpty, "System Settings does not list the app yet")
        #expect(fixture.presenter.dismissals == 0)
        #expect(pipeline.grantWaitCount == 0, "no grant can come while the app is closed")
        if pipeline.grantWaitCount > 0 { run.cancel() }
        await run.value
        #expect(feature.plays == 0)
    }

    @Test func anAppTheWorkspaceDoesNotKnowIsNamedPlainly() async {
        let (fixture, _) = await started()
        fixture.fakes.workspace.installed = []
        fixture.fakes.permissions.answer = .notDetermined
        let run = fixture.runtime.pipeline.runCommand(PlayerShaped.play, launch: .root)
        #expect(await waitUntil { !fixture.presenter.toasts.isEmpty || fixture.runtime.pipeline.grantWaitCount > 0 })
        if fixture.runtime.pipeline.grantWaitCount > 0 { run.cancel() }
        await run.value
        #expect(fixture.presenter.toasts.map(\.title) == ["The App Is Not Open"])
    }

    /// A running app that the user answered goes on as before.
    @Test func anAnswerFromARunningAppStillRunsOrOpensSettings() async {
        let (fixture, feature) = await started()
        let pipeline = fixture.runtime.pipeline
        fixture.fakes.permissions.answer = .granted
        await pipeline.runCommand(PlayerShaped.play, launch: .root).value
        #expect(feature.plays == 1)
        #expect(fixture.presenter.toasts.isEmpty)

        // Refused before, macOS shows nothing again: the pane is the way, as for any permission.
        fixture.fakes.permissions.set(PlayerShaped.player, to: .denied)
        fixture.fakes.permissions.answer = .denied
        let run = pipeline.runCommand(PlayerShaped.play, launch: .root)
        #expect(await waitUntil { pipeline.grantWaitCount == 1 })
        #expect(fixture.fakes.permissions.openedSettings == [PlayerShaped.player])
        run.cancel()
        await run.value
    }
}
