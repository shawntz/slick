import Darwin
import Foundation
import Kit
import KitTesting
import Synchronization
import Testing

@testable import MusicControls

@Suite("Live subtitle", .timeLimit(.minutes(1)))
@MainActor
struct SubtitleTests {
    static let music = SimulatedPlayers.musicQueue

    @Test func theRowShowsWhatPlaysAndWhere() async throws {
        let media = MediaHarness([.music: MediaHarness.playing(Self.music)])
        #expect(try await media.subtitleText() == "Playing “Example Song One” by Example Artist in Music")
    }

    @Test func theRowShowsAPausedTrack() async throws {
        let media = MediaHarness()
        #expect(try await media.subtitleText() == "Paused on “Example Song One” by Example Artist in Music")
        let value = try #require(await media.subtitle().value())
        #expect(value.color == nil, "the theme's color")
    }

    @Test func theRowShowsAnIdlePlayer() async throws {
        let media = MediaHarness([.music: MediaHarness.playing([], state: .stopped)])
        #expect(try await media.subtitleText() == "Nothing is playing in Music")
    }

    @Test func theRowShowsAPlayerThatDidNotAnswer() async throws {
        let media = MediaHarness()
        media.players.fail(.music, with: .timedOut(.music))
        #expect(try await media.subtitleText() == "Music did not answer")
    }

    @Test func fetchesWithinTwoSecondsAskThePlayersOnce() async throws {
        let media = MediaHarness()
        let subtitle = try media.subtitle()
        _ = await subtitle.value()
        media.clock.advance(by: .milliseconds(1_999))
        _ = await subtitle.value()
        _ = await subtitle.value()
        #expect(media.players.statusReads(of: .music) == 1)
        #expect(media.players.requests.count { $0 == .running } == 1)

        media.clock.advance(by: .milliseconds(1))
        _ = await subtitle.value()
        #expect(media.players.statusReads(of: .music) == 2, "two seconds later it asks again")
    }

    @Test func theRowFollowsAChangeAfterTheTwoSeconds() async throws {
        let media = MediaHarness()
        let subtitle = try media.subtitle()
        #expect(await subtitle.value()?.text == "Paused on “Example Song One” by Example Artist in Music")
        media.players.set(.music, MediaHarness.playing(Self.music, index: 1))
        #expect(await subtitle.value()?.text == "Paused on “Example Song One” by Example Artist in Music")
        media.clock.advance(by: .seconds(2))
        #expect(await subtitle.value()?.text == "Playing “Example Song Two” by Example Artist in Music")
    }

    @Test func overlappingFetchesShareOneAsk() async throws {
        let inner = SimulatedPlayers(MediaHarness.musicPaused)
        let held = HeldPlayers(inner)
        let media = MediaHarness(service: held)
        let subtitle = try media.subtitle()
        held.hold()
        let first = Task { await subtitle.value() }
        await held.waitForWaiting(1)
        let second = Task { await subtitle.value() }
        let third = Task { await subtitle.value() }
        // Whether the later fetches arrive while the ask waits or just after it ended, within the
        // two seconds they ask nothing.
        media.clock.advance(by: .milliseconds(100))
        held.release()
        let values = await [first.value, second.value, third.value]
        #expect(Set(values.map { $0?.text }) == ["Paused on “Example Song One” by Example Artist in Music"])
        #expect(inner.statusReads(of: .music) == 1)
        #expect(inner.requests.count { $0 == .running } == 1)
    }

    @Test func aCommandsAnswerWinsOverAnOlderAskStillUnderWay() async throws {
        let inner = SimulatedPlayers(MediaHarness.musicPaused)
        let held = HeldPlayers(inner)
        let media = MediaHarness(service: held)
        let subtitle = try media.subtitle()
        held.hold()
        let older = Task { await subtitle.value() }
        await held.waitForWaiting(1)
        let newer = NowPlaying(player: .music, state: .playing, track: Self.music[1], position: 0)
        media.feature.monitor.record(.player(newer))
        #expect(await subtitle.value()?.text == "Playing “Example Song Two” by Example Artist in Music")
        held.release()
        #expect(await older.value?.text == "Paused on “Example Song One” by Example Artist in Music")
        #expect(
            await subtitle.value()?.text == "Playing “Example Song Two” by Example Artist in Music",
            "the older ask ended later but does not replace the newer answer")
        #expect(inner.statusReads(of: .music) == 1)
    }

    @Test func aCommandHandsItsAnswerToTheRowWhichAsksNothingMore() async throws {
        let media = MediaHarness()
        let subtitle = try media.subtitle()
        let changes = try #require(subtitle.changes)
        let before = changes.generation
        try await media.harness.run("play-pause")
        #expect(changes.generation > before, "root search shows the new state at once")
        let reads = media.players.statusReads(of: .music)
        #expect(await subtitle.value()?.text == "Playing “Example Song One” by Example Artist in Music")
        #expect(media.players.statusReads(of: .music) == reads, "the command's own read is reused")
    }

    @Test func aClockSetBackMakesTheLastAnswerOld() async throws {
        let media = MediaHarness()
        let subtitle = try media.subtitle()
        _ = await subtitle.value()
        media.clock.set(media.clock.now.addingTimeInterval(-3_600))
        _ = await subtitle.value()
        #expect(media.players.statusReads(of: .music) == 2)
    }

    @Test func freshnessCountsOnlyForwardAndUnderTwoSeconds() {
        let asked = Date(timeIntervalSince1970: 1_000)
        #expect(NowPlayingMonitor.isFresh(asked, now: asked))
        #expect(NowPlayingMonitor.isFresh(asked, now: asked.addingTimeInterval(1.9)))
        #expect(!NowPlayingMonitor.isFresh(asked, now: asked.addingTimeInterval(2)))
        #expect(!NowPlayingMonitor.isFresh(asked, now: asked.addingTimeInterval(-0.5)))
    }

    @Test func theRowAsksThePlayersOffTheMainThread() async throws {
        let recorder = ThreadRecordingPlayers(SimulatedPlayers(MediaHarness.musicPaused))
        let media = MediaHarness(service: recorder)
        _ = try await media.subtitleText()
        try await media.harness.run("play-pause")
        #expect(!recorder.calls.isEmpty)
        #expect(recorder.calls.allSatisfy { !$0 }, "no call ran on the main thread")
    }

    @Test func theFeatureAsksNothingByItselfWhileNobodyLooks() async throws {
        let media = MediaHarness()
        await media.harness.activate()
        try await media.harness.settle()
        media.clock.advance(by: .seconds(600))
        try await media.harness.settle()
        #expect(media.players.requests.isEmpty, "no timer of its own")
        #expect(media.clock.sleeperCount == 0)
        await media.harness.deactivate()
        await media.harness.activate()
        #expect(media.players.requests.isEmpty)
    }

    @Test func aHotkeyRunWhileThePanelIsHiddenAsksOnlyForTheCommand() async throws {
        let media = MediaHarness()
        await media.harness.activate()
        try await media.harness.run("play-pause", launch: .hotkey)
        let afterCommand = media.players.requests
        media.clock.advance(by: .seconds(60))
        try await media.harness.settle()
        #expect(media.players.requests == afterCommand, "the change signal alone asks nothing")
        #expect(afterCommand == [.running, .status(.music), .send(.playPause, .music), .status(.music)])
    }
}

/// A player service that notes, for every call, whether it ran on the main thread.
nonisolated final class ThreadRecordingPlayers: PlayerService {
    private let inner: SimulatedPlayers
    private let onMain = Mutex<[Bool]>([])

    init(_ inner: SimulatedPlayers) {
        self.inner = inner
    }

    /// One entry per call: true when it ran on the main thread.
    var calls: [Bool] { onMain.withLock { $0 } }

    private func note() {
        let isMain = pthread_main_np() != 0
        onMain.withLock { $0.append(isMain) }
    }

    func runningPlayers() async -> [Player] {
        note()
        return await inner.runningPlayers()
    }

    func status(of player: Player) async throws -> NowPlaying {
        note()
        return try await inner.status(of: player)
    }

    func send(_ transport: Transport, to player: Player) async throws {
        note()
        try await inner.send(transport, to: player)
    }
}
