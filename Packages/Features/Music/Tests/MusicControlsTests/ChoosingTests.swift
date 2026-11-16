import Foundation
import Kit
import KitTesting
import Testing

@testable import MusicControls

@Suite("Which player", .timeLimit(.minutes(1)))
@MainActor
struct ChoosingTests {
    static let music = SimulatedPlayers.musicQueue
    static let spotify = SimulatedPlayers.spotifyQueue

    @Test func theOnlyRunningPlayerIsTheOneControlled() async throws {
        let media = MediaHarness([
            .music: MediaHarness.stopped(Self.music), .spotify: MediaHarness.playing(Self.spotify, state: .paused),
        ])
        try await media.harness.run("play-pause")
        #expect(media.players.sent == [.send(.playPause, .spotify)])
        #expect(media.hudTitles == ["Playing “Sample Track A” by Sample Band"])
    }

    @Test func whenBothRunTheOneThatPlaysWinsOverThePreferredOne() async throws {
        let media = MediaHarness([
            .music: MediaHarness.playing(Self.music, state: .paused), .spotify: MediaHarness.playing(Self.spotify),
        ])
        #expect(media.settings[MediaSettings.preferredPlayer] == .music)
        try await media.harness.run("play-pause")
        #expect(media.players.sent == [.send(.playPause, .spotify)])
        #expect(media.hudTitles == ["Paused “Sample Track A” by Sample Band"])
        #expect(media.players.app(.music)?.state == .paused, "the other player is left alone")
    }

    @Test(arguments: [Player.music, .spotify])
    func whenBothRunAndNeitherPlaysThePreferredOneIsControlled(preferred: Player) async throws {
        let media = MediaHarness([
            .music: MediaHarness.playing(Self.music, state: .paused),
            .spotify: MediaHarness.playing(Self.spotify, state: .paused),
        ])
        media.settings[MediaSettings.preferredPlayer] = preferred
        try await media.harness.run("play-pause")
        #expect(media.players.sent == [.send(.playPause, preferred)])
    }

    @Test(arguments: [Player.music, .spotify])
    func whenBothPlayThePreferredOneIsControlled(preferred: Player) async throws {
        let media = MediaHarness([
            .music: MediaHarness.playing(Self.music), .spotify: MediaHarness.playing(Self.spotify),
        ])
        media.settings[MediaSettings.preferredPlayer] = preferred
        try await media.harness.run("next-track")
        #expect(media.players.sent == [.send(.next, preferred)])
    }

    @Test func noEventEverReachesAPlayerThatIsNotRunning() async throws {
        let media = MediaHarness([
            .music: MediaHarness.playing(Self.music), .spotify: MediaHarness.stopped(Self.spotify),
        ])
        media.settings[MediaSettings.preferredPlayer] = .spotify
        for id in DeclarationTests.commandIDs {
            try await media.harness.run(id)
        }
        _ = try await media.subtitleText()
        let reachedSpotify = media.players.requests.filter { request in
            switch request {
            case .running: false
            case .status(let player), .send(_, let player): player == .spotify
            }
        }
        #expect(reachedSpotify.isEmpty)
        #expect(media.players.sent.count == 3)
        #expect(media.fakes.workspace.launched.isEmpty, "the preferred player was not started")
    }

    // MARK: - Permissions while both run

    @Test func aRunningPlayerNeverAskedAboutStopsTheChoiceUntilTheUserAnswers() async throws {
        let media = MediaHarness([
            .music: MediaHarness.playing(Self.music, state: .paused),
            .spotify: MediaHarness.playing(Self.spotify, state: .paused),
        ])
        media.fakes.permissions.set(Player.spotify.permission, to: .notDetermined)
        await #expect(throws: HarnessError.permissionRequired([Player.spotify.permission])) {
            try await media.harness.run("play-pause")
        }
        #expect(media.players.sent.isEmpty, "Spotify may be the one that plays")
        #expect(media.fakes.permissions.requests.isEmpty, "only the host's card asks")
    }

    @Test func aPlayerTheUserRefusedIsLeftOutWhenAnotherRuns() async throws {
        let media = MediaHarness([
            .music: MediaHarness.playing(Self.music, state: .paused),
            .spotify: MediaHarness.playing(Self.spotify),
        ])
        media.fakes.permissions.set(Player.spotify.permission, to: .denied)
        try await media.harness.run("play-pause")
        #expect(media.players.sent == [.send(.playPause, .music)])
        #expect(media.fakes.permissions.requests.isEmpty)
    }

    @Test func aPlayingPlayerWinsEvenWhenTheOtherWasNeverAskedAbout() async throws {
        let media = MediaHarness([
            .music: MediaHarness.playing(Self.music), .spotify: MediaHarness.playing(Self.spotify),
        ])
        media.fakes.permissions.set(Player.spotify.permission, to: .notDetermined)
        try await media.harness.run("play-pause")
        #expect(media.players.sent == [.send(.playPause, .music)])
    }

    // MARK: - The rule alone

    @Test func theRuleKeepsTheOrderItWasGiven() {
        let paused = NowPlaying(player: .music, state: .paused, track: Self.music[0])
        let playing = NowPlaying(player: .spotify, state: .playing, track: Self.spotify[0])
        typealias Reading = Result<NowPlaying, PlayerFailure>
        #expect(PlayerChooser.decide([]) == .none)
        #expect(PlayerChooser.decide([Reading.success(paused), .success(playing)]) == .player(playing))
        #expect(PlayerChooser.decide([Reading.success(paused)]) == .player(paused))
        #expect(
            PlayerChooser.decide([Reading.success(paused), .failure(.permissionNeeded(.spotify))])
                == .failure(.permissionNeeded(.spotify)))
        #expect(
            PlayerChooser.decide([Reading.success(paused), .failure(.permissionDenied(.spotify))]) == .player(paused))
        #expect(PlayerChooser.decide([Reading.success(paused), .failure(.timedOut(.spotify))]) == .player(paused))
        #expect(PlayerChooser.decide([Reading.failure(.notRunning(.music)), .failure(.notRunning(.spotify))]) == .none)
        #expect(
            PlayerChooser.decide([Reading.failure(.notRunning(.music)), .failure(.timedOut(.spotify))])
                == .failure(.timedOut(.spotify)))
        #expect(
            PlayerChooser.decide([Reading.failure(.permissionDenied(.music)), .failure(.timedOut(.spotify))])
                == .failure(.permissionDenied(.music)))
    }

    @Test func thePreferredPlayerIsAskedFirst() {
        #expect(Player.ordered(preferring: .music) == [.music, .spotify])
        #expect(Player.ordered(preferring: .spotify) == [.spotify, .music])
    }
}

@Suite("No player", .timeLimit(.minutes(1)))
@MainActor
struct NoPlayerTests {
    @Test(arguments: DeclarationTests.offersToOpenIDs)
    func everyCommandOffersToOpenThePreferredPlayerAndStartsNothingUnasked(id: String) async throws {
        let media = MediaHarness(MediaHarness.nothingRunning)
        media.harness.confirmationAnswer = false
        let outcome = try await media.harness.run(id)
        #expect(outcome.kind == .keepOpen)
        let question = try #require(media.harness.confirmations.first)
        #expect(question.title == "Open Music?")
        #expect(question.message?.hasPrefix("No player is running.") == true)
        #expect(question.confirmTitle == "Open Music")
        #expect(question.isDestructive == false)
        #expect(media.fakes.workspace.launched.isEmpty)
        #expect(media.players.requests == [.running], "only the list of running apps was read")
        #expect(media.hudTitles.isEmpty)
    }

    @Test func sayingYesOpensThePreferredPlayerAndNothingMore() async throws {
        let media = MediaHarness(MediaHarness.nothingRunning)
        let outcome = try await media.harness.run("play-pause")
        #expect(outcome.kind == .close(hud: HUD("Opened Music")))
        #expect(media.fakes.workspace.launched == ["com.apple.Music"])
        #expect(media.hudTitles == ["Opened Music"])
        #expect(media.players.sent.isEmpty, "opening is all it does; the user plays next")
    }

    @Test func thePreferredPlayerIsTheOneOffered() async throws {
        let media = MediaHarness(MediaHarness.nothingRunning)
        media.settings[MediaSettings.preferredPlayer] = .spotify
        try await media.harness.run("next-track")
        #expect(media.harness.confirmations.map(\.title) == ["Open Spotify?"])
        #expect(media.fakes.workspace.launched == ["com.spotify.client"])
        #expect(media.hudTitles == ["Opened Spotify"])
    }

    @Test func aHotkeyWithNoPlayerAsksTooAndNeverStartsOneBySurprise() async throws {
        let media = MediaHarness(MediaHarness.nothingRunning)
        media.harness.confirmationAnswer = false
        try await media.harness.run("play-pause", launch: .hotkey)
        #expect(media.harness.confirmations.count == 1)
        #expect(media.fakes.workspace.launched.isEmpty)
    }

    @Test func theRowSaysNoPlayerIsRunning() async throws {
        let media = MediaHarness(MediaHarness.nothingRunning)
        #expect(try await media.subtitleText() == "No player is running")
        #expect(media.fakes.workspace.launched.isEmpty)
    }

    @Test func aPlayerThatCannotBeOpenedSaysSoAndClosesNothing() async throws {
        let media = MediaHarness(MediaHarness.nothingRunning)
        media.settings[MediaSettings.preferredPlayer] = .spotify
        media.fakes.workspace.refusesToLaunch = ["com.spotify.client"]
        media.harness.throwsActionErrors = false
        let outcome = try await media.harness.run("play-pause")
        #expect(media.harness.confirmations.map(\.title) == ["Open Spotify?"])
        #expect(outcome.kind == .keepOpen)
        #expect(media.harness.isClosed == false)
        #expect(media.harness.toasts.map(\.title) == ["Could Not Open Spotify"])
        #expect(
            media.harness.toasts.first?.message
                == "Spotify may not be installed. Choose another preferred player in settings.")
        #expect(media.hudTitles.isEmpty, "no Opened HUD")
        #expect(media.fakes.workspace.launched.isEmpty)
        #expect(media.players.sent.isEmpty)
    }

    @Test func theWordsWhenAPlayerCannotBeOpened() {
        #expect(Strings.Open.failed(.spotify) == "Could Not Open Spotify")
        #expect(
            Strings.Open.failedMessage(.spotify)
                == "Spotify may not be installed. Choose another preferred player in settings.")
    }
}
