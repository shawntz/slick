import Foundation
import Kit
import KitTesting
import Synchronization
import Testing

@testable import MusicControls

/// A second engineer's attempts to break the feature: a run cancelled mid-way, a player that quits
/// or loses its permission between the choice and the event, both players refused, and every
/// command against a player that is not running.
@Suite("Second pass", .timeLimit(.minutes(1)))
struct SecondPassTests {
    /// Turning the feature off cancels its handlers, as the host does. A run cancelled while it
    /// asks the players sends nothing and says nothing.
    @Test func aRunCancelledWhileThePlayersAreAskedSendsNothing() async throws {
        let inner = SimulatedPlayers(MediaHarness.musicPaused)
        let held = HeldPlayers(inner)
        let media = MediaHarness(service: held)
        held.hold()
        let handler = try media.harness.command(MediaCommandID.playPause).run
        let context = ActionContext(feature: media.harness.context, host: media.harness, launch: .hotkey)
        let run = Task { try await handler(context) }
        await held.waitForWaiting(1)
        run.cancel()
        held.release()
        await #expect(throws: CancellationError.self) { _ = try await run.value }
        #expect(inner.sent.isEmpty, "no event after the cancel")
        #expect(media.harness.huds.isEmpty)
    }

    /// A Yes to "Open Music?" from a run that was cancelled opens nothing.
    @Test func aCancelledRunOpensNoPlayer() async throws {
        let media = MediaHarness(MediaHarness.nothingRunning)
        let handler = try media.harness.command(MediaCommandID.next).run
        let context = ActionContext(feature: media.harness.context, host: media.harness, launch: .hotkey)
        let run = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await handler(context)
        }
        await #expect(throws: CancellationError.self) { _ = try await run.value }
        #expect(media.harness.confirmations.map(\.title) == ["Open Music?"])
        #expect(media.fakes.workspace.launched.isEmpty)
    }

    /// The player quits after it was chosen and before the event. The event goes nowhere, nothing
    /// starts, and a HUD says so, since the panel has closed.
    @Test func aPlayerThatQuitsBetweenTheChoiceAndTheEventGetsNothing() async throws {
        let fakes = FakeServices()
        let inner = SimulatedPlayers(MediaHarness.musicPaused, permissions: PermissionReader(fakes.permissions))
        let quit = MediaHarness.stopped(SimulatedPlayers.musicQueue)
        fakes.override(PlayerServiceKey.self, with: AfterReadPlayers(inner) { inner.set(.music, quit) })
        let harness = FeatureHarness(MediaControlsFeature.self, fakes: fakes)
        harness.throwsActionErrors = false
        for id in [MediaCommandID.playPause, MediaCommandID.next, MediaCommandID.previous] {
            inner.set(.music, MediaHarness.playing(SimulatedPlayers.musicQueue, state: .paused, position: 83))
            try await harness.run(id)
        }
        #expect(inner.sent.isEmpty)
        #expect(harness.huds.map(\.title) == Array(repeating: "Music Is Not Running", count: 3))
        #expect(harness.huds.allSatisfy { $0.style == .failure })
        #expect(fakes.workspace.launched.isEmpty)
    }

    /// Automation is taken away after the choice. Nothing is sent, and the host's card asks again.
    @Test func accessTakenAwayAfterTheChoiceSendsNothing() async throws {
        let fakes = FakeServices()
        let inner = SimulatedPlayers(MediaHarness.musicPaused, permissions: PermissionReader(fakes.permissions))
        let music = Player.music.permission
        let permissions = fakes.permissions
        fakes.override(PlayerServiceKey.self, with: AfterReadPlayers(inner) { permissions.set(music, to: .denied) })
        let harness = FeatureHarness(MediaControlsFeature.self, fakes: fakes)
        await #expect(throws: HarnessError.permissionRequired([music])) {
            try await harness.run(MediaCommandID.playPause)
        }
        #expect(inner.sent.isEmpty)
    }

    /// Both players run and the user refused both. Every command shows the host's card for the
    /// preferred one and nothing reaches either player.
    @Test func bothPlayersRefusedReachNeither() async throws {
        let media = MediaHarness(
            [
                .music: MediaHarness.playing(SimulatedPlayers.musicQueue),
                .spotify: MediaHarness.playing(SimulatedPlayers.spotifyQueue),
            ], permissions: .denied)
        for id in DeclarationTests.commandIDs {
            await #expect(throws: HarnessError.permissionRequired([Player.music.permission]), "\(id)") {
                try await media.harness.run(id)
            }
        }
        #expect(media.players.requests.allSatisfy { $0 == .running }, "no player was asked or sent anything")
        #expect(try await media.subtitleText() == "Run it once to allow control of Music")
        #expect(media.fakes.permissions.requests.isEmpty, "only the host's card asks")
    }

    /// Both players run, Spotify plays and the user prefers Music. Every transport command goes to
    /// Spotify, and Music is only read.
    @Test func bothRunningSendsOnlyToThePlayerThatPlays() async throws {
        let media = MediaHarness([
            .music: MediaHarness.playing(SimulatedPlayers.musicQueue, state: .paused),
            .spotify: MediaHarness.playing(SimulatedPlayers.spotifyQueue),
        ])
        try await media.harness.run(MediaCommandID.next)
        try await media.harness.run(MediaCommandID.playPause)
        #expect(media.players.sent == [.send(.next, .spotify), .send(.playPause, .spotify)])
        #expect(media.hudTitles.first == "Playing “Sample Track B” by Sample Band")
    }

    /// With no player running, no command, no subtitle and no deep link sends an event or starts a
    /// player unless the user says Open.
    @Test func nothingRunningMeansNoEventFromAnyPath() async throws {
        let media = MediaHarness(MediaHarness.nothingRunning)
        media.harness.confirmationAnswer = false
        for id in DeclarationTests.commandIDs {
            for launch in [LaunchSource.root, .hotkey, .deeplink, .command] {
                try await media.harness.run(id, launch: launch)
            }
        }
        for _ in 0..<3 {
            #expect(try await media.subtitleText() == "No player is running")
            media.clock.advance(by: .seconds(3))
        }
        #expect(media.players.requests.allSatisfy { $0 == .running })
        #expect(media.fakes.workspace.launched.isEmpty)
        #expect(media.harness.confirmations.count == DeclarationTests.offersToOpenIDs.count * 4)
    }
}

/// Players that run a step after every read of a player's state, such as quitting it or taking
/// its permission away, so the next call finds the change.
nonisolated final class AfterReadPlayers: PlayerService {
    private let inner: SimulatedPlayers
    private let afterRead: @Sendable () -> Void

    init(_ inner: SimulatedPlayers, afterRead: @escaping @Sendable () -> Void) {
        self.inner = inner
        self.afterRead = afterRead
    }

    func runningPlayers() async -> [Player] { await inner.runningPlayers() }

    func status(of player: Player) async throws -> NowPlaying {
        let now = try await inner.status(of: player)
        afterRead()
        return now
    }

    func send(_ transport: Transport, to player: Player) async throws {
        try await inner.send(transport, to: player)
    }
}
