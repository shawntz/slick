import Foundation
import Kit
import KitTesting
import Testing

@testable import MusicControls

@Suite("Transport", .timeLimit(.minutes(1)))
@MainActor
struct TransportTests {
    static let music = SimulatedPlayers.musicQueue

    @Test func playOrPauseStartsAPausedPlayerAndSaysWhatPlays() async throws {
        let media = MediaHarness()
        let outcome = try await media.harness.run("play-pause")
        #expect(outcome.closesPanel)
        #expect(media.hudTitles == ["Playing “Example Song One” by Example Artist"])
        #expect(media.players.sent == [.send(.playPause, .music)])
        #expect(media.players.app(.music)?.state == .playing)
        #expect(media.harness.isClosed)
    }

    @Test func playOrPauseTwicePausesAgain() async throws {
        let media = MediaHarness()
        try await media.harness.run("play-pause")
        try await media.harness.run("play-pause")
        #expect(
            media.hudTitles == [
                "Playing “Example Song One” by Example Artist", "Paused “Example Song One” by Example Artist",
            ])
        #expect(media.players.app(.music)?.state == .paused)
    }

    @Test func nextTrackSaysTheNewTitle() async throws {
        let media = MediaHarness([.music: MediaHarness.playing(Self.music)])
        try await media.harness.run("next-track")
        #expect(media.hudTitles == ["Playing “Example Song Two” by Example Artist"])
        #expect(media.players.sent == [.send(.next, .music)])
    }

    @Test func skippingWhilePausedSaysWhereItLanded() async throws {
        let media = MediaHarness([.music: MediaHarness.playing(Self.music, index: 1, state: .paused)])
        try await media.harness.run("next-track")
        try await media.harness.run("previous-track")
        try await media.harness.run("previous-track")
        #expect(
            media.hudTitles == [
                "Skipped to “Example Song Three” by Example Artist",
                "Went Back to “Example Song Two” by Example Artist",
                "Went Back to “Example Song One” by Example Artist",
            ])
        #expect(media.players.app(.music)?.state == .paused, "a skip never starts playback")
    }

    @Test func repeatedSkipsEachStartWhereTheLastOneLanded() async throws {
        let media = MediaHarness([.music: MediaHarness.playing(Self.music)])
        async let first = media.harness.run("next-track")
        async let second = media.harness.run("next-track")
        _ = try await (first, second)
        #expect(media.players.app(.music)?.index == 2)
        #expect(
            media.hudTitles == [
                "Playing “Example Song Two” by Example Artist", "Playing “Example Song Three” by Example Artist",
            ], "each press reports its own track")
    }

    @Test func nextTrackAtTheEndOfTheQueueSaysSo() async throws {
        let media = MediaHarness([.music: MediaHarness.playing(Self.music, index: 2)])
        try await media.harness.run("next-track")
        #expect(media.hudTitles == ["No More Tracks in Music"])
    }

    @Test func playOrPauseWithNothingQueuedSaysSo() async throws {
        let media = MediaHarness([.music: MediaHarness.playing([], state: .stopped)])
        try await media.harness.run("play-pause")
        #expect(media.hudTitles == ["Nothing to Play in Music"])
        #expect(media.players.sent == [.send(.playPause, .music)])
    }

    @Test func nowPlayingShowsTitleArtistAlbumPlayerAndTimeAndSendsNothing() async throws {
        let media = MediaHarness()
        let outcome = try await media.harness.run("now-playing")
        #expect(outcome.closesPanel)
        #expect(
            media.hudTitles == [
                "“Example Song One” by Example Artist · Example Album · Paused in Music · 1:23 of 4:05"
            ])
        #expect(media.players.sent.isEmpty)
    }

    @Test func nowPlayingWhilePlayingSaysPlaying() async throws {
        let media = MediaHarness([.spotify: MediaHarness.playing(SimulatedPlayers.spotifyQueue, position: 65)])
        try await media.harness.run("now-playing")
        #expect(
            media.hudTitles == ["“Sample Track A” by Sample Band · Sample Record · Playing in Spotify · 1:05 of 3:21"])
    }

    @Test func nowPlayingWithNothingPlayingSaysSo() async throws {
        let media = MediaHarness([.music: MediaHarness.playing([], state: .stopped)])
        try await media.harness.run("now-playing")
        #expect(media.hudTitles == ["Nothing Is Playing in Music"])
    }

    @Test func aHotkeyRunNeedsNoPanelAndEndsWithAHUD() async throws {
        let media = MediaHarness()
        try await media.harness.run("next-track", launch: .hotkey)
        #expect(media.hudTitles == ["Skipped to “Example Song Two” by Example Artist"])
        #expect(media.harness.confirmations.isEmpty)
        #expect(media.harness.toasts.isEmpty)
    }

    @Test(arguments: DeclarationTests.commandIDs)
    func eachCommandRunsFromADeepLinkAndTouchesNoData(id: String) async throws {
        let media = MediaHarness()
        let outcome = try await media.harness.run(id, launch: .deeplink)
        #expect(outcome.closesPanel)
        #expect(media.hudTitles.count == 1)
        #expect(media.fakes.pasteboard.copiedTexts.isEmpty)
        #expect(media.fakes.pasteboard.pastedTexts.isEmpty)
        #expect(media.fakes.workspace.launched.isEmpty)
        #expect(media.fakes.workspace.opened.isEmpty)
        #expect(media.harness.issues.isEmpty)
    }

    // MARK: - A player that lags after a skip

    @Test func aSkipReadsAgainUntilThePlayerShowsTheNewTrack() async throws {
        let media = MediaHarness([.spotify: MediaHarness.playing(SimulatedPlayers.spotifyQueue)])
        media.players.setLag(.spotify, reads: 2)
        let run = Task { try await media.harness.run("next-track") }
        for _ in 0..<2 {
            await media.clock.waitForSleepers(1)
            media.clock.advance(by: MediaControlsFeature.skipWait)
        }
        _ = try await run.value
        #expect(media.hudTitles == ["Playing “Sample Track B” by Sample Band"])
        // One read to choose, then three after the skip: two stale, one new.
        #expect(media.players.statusReads(of: .spotify) == 4)
    }

    @Test func aPlayerThatNeverShowsTheSkipIsReadOnlyAFewTimes() async throws {
        let media = MediaHarness([.spotify: MediaHarness.playing(SimulatedPlayers.spotifyQueue)])
        media.players.setLag(.spotify, reads: 100)
        let run = Task { try await media.harness.run("next-track") }
        for _ in 0..<MediaControlsFeature.skipChecks {
            await media.clock.waitForSleepers(1)
            media.clock.advance(by: MediaControlsFeature.skipWait)
        }
        _ = try await run.value
        #expect(media.players.statusReads(of: .spotify) == 2 + MediaControlsFeature.skipChecks)
        #expect(media.hudTitles == ["Playing “Sample Track A” by Sample Band"], "it reports what the player says")
    }

    @Test func aSkipShowsByTheTrackOrByAPositionThatWentBack() {
        let one = Track(title: "One", duration: 100)
        let two = Track(title: "Two", duration: 100)
        let before = NowPlaying(player: .music, state: .playing, track: one, position: 40)
        #expect(
            MediaControlsFeature.hasMoved(from: before, to: NowPlaying(player: .music, state: .playing, track: two)))
        #expect(MediaControlsFeature.hasMoved(from: before, to: NowPlaying(player: .music, state: .stopped)))
        #expect(
            MediaControlsFeature.hasMoved(
                from: before, to: NowPlaying(player: .music, state: .playing, track: one, position: 0.2)),
            "the same song again, from the start")
        #expect(
            !MediaControlsFeature.hasMoved(
                from: before, to: NowPlaying(player: .music, state: .playing, track: one, position: 40.5)))
        #expect(
            !MediaControlsFeature.hasMoved(from: before, to: NowPlaying(player: .music, state: .playing, track: one)))
    }

    // MARK: - Failures

    @Test func aPlayerThatQuitsWhileItIsAskedCountsAsNotRunning() async throws {
        let media = MediaHarness()
        media.players.fail(.music, with: .notRunning(.music))
        // It still shows as running, then the read finds it gone: no player to act on.
        media.harness.confirmationAnswer = false
        let outcome = try await media.harness.run("play-pause")
        #expect(outcome.kind == .keepOpen)
        #expect(media.harness.confirmations.map(\.title) == ["Open Music?"])
        #expect(media.players.sent.isEmpty)
    }

    @Test(arguments: [
        (PlayerFailure.timedOut(.music), "Music Did Not Answer", "Try again in a moment."),
        (PlayerFailure.failed(.music, code: -1708), "Could Not Control Music", "macOS returned error -1708."),
    ])
    func aPlayerThatFailsSaysWhyInTheFeaturesWords(failure: PlayerFailure, title: String, message: String) async throws
    {
        let media = MediaHarness()
        media.players.fail(.music, with: failure)
        try await media.runShowingErrors("play-pause")
        #expect(media.harness.toasts.map(\.title) == [title])
        #expect(media.harness.toasts.first?.message == message)
        #expect(media.players.sent.isEmpty)
    }

    @Test func aFailureAfterThePanelClosedShowsAsAHUD() async throws {
        let failing = FailingSendPlayers(MediaHarness.musicPaused, failure: .timedOut(.music))
        let media = MediaHarness(service: failing)
        try await media.runShowingErrors("play-pause")
        #expect(media.harness.huds.map(\.title) == ["Music Did Not Answer"])
        #expect(media.harness.huds.first?.style == .failure)
    }

    @Test func eachFailureMapsToTheCardOrToWords() throws {
        #expect(
            try MediaControlsFeature.outcome(for: .permissionNeeded(.music)).kind
                == .needsPermission(.automation(bundleID: "com.apple.Music")))
        #expect(
            try MediaControlsFeature.outcome(for: .permissionDenied(.spotify)).kind
                == .needsPermission(.automation(bundleID: "com.spotify.client")))
        #expect(throws: ActionFailure("Spotify Is Not Running", message: "It quit before the command reached it.")) {
            try MediaControlsFeature.outcome(for: .notRunning(.spotify))
        }
    }
}

/// Players whose transport commands fail after they were read, as when a player hangs on the
/// command itself.
nonisolated final class FailingSendPlayers: PlayerService {
    private let inner: SimulatedPlayers
    private let failure: PlayerFailure

    init(_ apps: [Player: SimulatedPlayers.App], failure: PlayerFailure) {
        inner = SimulatedPlayers(apps)
        self.failure = failure
    }

    func runningPlayers() async -> [Player] { await inner.runningPlayers() }
    func status(of player: Player) async throws -> NowPlaying { try await inner.status(of: player) }
    func send(_ transport: Transport, to player: Player) async throws { throw failure }
}
