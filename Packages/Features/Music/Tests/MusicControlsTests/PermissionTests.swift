import Foundation
import Kit
import KitTesting
import Testing

@testable import MusicControls

@Suite("Permissions", .timeLimit(.minutes(1)))
@MainActor
struct PermissionTests {
    @Test(arguments: [PermissionStatus.notDetermined, .denied, .restricted])
    func aPlayerThatMayNotBeControlledGetsTheHostsCardAndNothingIsSent(status: PermissionStatus) async throws {
        let media = MediaHarness()
        media.fakes.permissions.set(Player.music.permission, to: status)
        for id in DeclarationTests.commandIDs {
            await #expect(throws: HarnessError.permissionRequired([Player.music.permission])) {
                try await media.harness.run(id)
            }
        }
        #expect(media.players.requests == Array(repeating: .running, count: DeclarationTests.commandIDs.count))
        #expect(media.fakes.permissions.requests.isEmpty, "nothing prompts until the user presses Grant")
        #expect(media.hudTitles.isEmpty)
        #expect(!media.harness.isClosed, "the panel stays for the card")
    }

    @Test func afterTheGrantTheCommandRunsAgainAndWorks() async throws {
        let media = MediaHarness()
        media.fakes.permissions.set(Player.music.permission, to: .notDetermined)
        media.harness.grantsMissingPermissions = true
        try await media.harness.run("play-pause")
        #expect(media.fakes.permissions.requests == [Player.music.permission])
        #expect(media.players.sent == [.send(.playPause, .music)])
        #expect(media.hudTitles == ["Playing “Example Song One” by Example Artist"])
    }

    @Test func spotifyAsksForItsOwnPermission() async throws {
        let media = MediaHarness([.spotify: MediaHarness.playing(SimulatedPlayers.spotifyQueue)])
        media.fakes.permissions.set(Player.spotify.permission, to: .notDetermined)
        await #expect(throws: HarnessError.permissionRequired([Player.spotify.permission])) {
            try await media.harness.run("next-track")
        }
    }

    @Test func theRowSaysWhatIsMissingAndAsksForNothing() async throws {
        let media = MediaHarness()
        media.fakes.permissions.set(Player.music.permission, to: .notDetermined)
        #expect(try await media.subtitleText() == "Run it once to allow control of Music")
        #expect(media.fakes.permissions.requests.isEmpty)
        #expect(media.players.sent.isEmpty)
    }

    @Test func theFeatureHoldsNoPermissionStream() async throws {
        let media = MediaHarness(permissions: .notDetermined)
        await media.harness.activate()
        _ = try? await media.harness.run("play-pause")
        _ = try await media.subtitleText()
        try await media.harness.settle()
        #expect(media.fakes.permissions.openStreamCount == 0)
        await media.harness.deactivate()
    }

    @Test func aGrantInSettingsNeedsNothingFromTheFeature() async throws {
        let media = MediaHarness(permissions: .notDetermined)
        await media.harness.activate()
        try await media.harness.grantInSettings(Player.spotify.permission)
        #expect(media.players.requests.isEmpty, "a grant asks no player anything by itself")
        #expect(media.fakes.permissions.openStreamCount == 0)
    }
}
