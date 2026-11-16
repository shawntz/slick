import Foundation
import Kit
import KitTesting
import Testing

@testable import MusicControls

/// Pause only ever pauses. Typing "pause" while a video plays in a browser must not start the
/// paused player, as Play or Pause would.
@Suite("Pause", .timeLimit(.minutes(1)))
@MainActor
struct PauseTests {
    static let music = SimulatedPlayers.musicQueue

    @Test func pauseLeavesAPausedPlayerPausedAndSendsNothing() async throws {
        let media = MediaHarness()
        let outcome = try await media.harness.run(MediaCommandID.pause)
        #expect(outcome.closesPanel)
        #expect(media.hudTitles == ["Music Is Already Paused"])
        #expect(media.players.sent.isEmpty)
        #expect(media.players.app(.music)?.state == .paused)
    }

    @Test func pausePausesAPlayingPlayer() async throws {
        let media = MediaHarness([.music: MediaHarness.playing(Self.music)])
        try await media.harness.run(MediaCommandID.pause)
        #expect(media.players.sent == [.send(.pause, .music)])
        #expect(media.players.app(.music)?.state == .paused)
        #expect(media.hudTitles == ["Paused “Example Song One” by Example Artist"])
    }

    @Test func pausePausesThePlayerThatPlays() async throws {
        let media = MediaHarness([
            .music: MediaHarness.playing(Self.music, state: .paused),
            .spotify: MediaHarness.playing(SimulatedPlayers.spotifyQueue),
        ])
        try await media.harness.run(MediaCommandID.pause)
        #expect(media.players.sent == [.send(.pause, .spotify)])
    }

    @Test func pauseWithAStoppedPlayerSaysNothingPlays() async throws {
        let media = MediaHarness([.music: MediaHarness.playing([], state: .stopped)])
        try await media.harness.run(MediaCommandID.pause)
        #expect(media.players.sent.isEmpty)
        #expect(media.hudTitles == ["Nothing Is Playing in Music"])
    }

    @Test func pauseWithNoPlayerRunningOffersToOpenNothing() async throws {
        let media = MediaHarness(MediaHarness.nothingRunning)
        let outcome = try await media.harness.run(MediaCommandID.pause)
        #expect(outcome.closesPanel)
        #expect(media.harness.confirmations.isEmpty, "there is nothing to pause, so nothing to open")
        #expect(media.fakes.workspace.launched.isEmpty)
        #expect(media.hudTitles == ["Nothing Is Playing"])
    }

    @Test func pauseAsksForThePermissionThePlayerNeeds() async throws {
        let media = MediaHarness([.music: MediaHarness.playing(Self.music)])
        media.fakes.permissions.set(Player.music.permission, to: .notDetermined)
        await #expect(throws: HarnessError.permissionRequired([Player.music.permission])) {
            try await media.harness.run(MediaCommandID.pause)
        }
        #expect(media.players.sent.isEmpty)
        #expect(media.fakes.permissions.requests.isEmpty)
    }

    @Test func pauseIsItsOwnCommandTitledPause() throws {
        let media = MediaHarness()
        let pause = try media.harness.command(MediaCommandID.pause)
        #expect(pause.title == "Pause")
        #expect(pause.keywords.contains("stop playback"))
        #expect(media.harness.issues.isEmpty)
        let playPause = try media.harness.command(MediaCommandID.playPause)
        #expect(!playPause.keywords.contains("pause"), "the word belongs to Pause now")
    }
}
