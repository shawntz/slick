import Foundation
import Kit
import KitTesting
import Synchronization
import Testing

@testable import MusicControls

/// The feature over simulated players, so every command runs and nothing reaches an app.
@MainActor
struct MediaHarness {
    let players: SimulatedPlayers
    let harness: FeatureHarness<MediaControlsFeature>

    /// - Parameters:
    ///   - apps: The simulated apps. Music runs, paused in its queue, unless the test says
    ///     otherwise.
    ///   - service: A different service for the feature, such as one that counts or holds asks.
    init(
        _ apps: [Player: SimulatedPlayers.App] = MediaHarness.musicPaused, permissions: PermissionStatus = .granted,
        service: (any PlayerService)? = nil
    ) {
        let fakes = FakeServices(permissions: permissions)
        players = SimulatedPlayers(apps, permissions: PermissionReader(fakes.permissions))
        fakes.override(PlayerServiceKey.self, with: service ?? players)
        harness = FeatureHarness(MediaControlsFeature.self, fakes: fakes)
    }

    var fakes: FakeServices { harness.fakes }
    var settings: FeatureSettings { harness.context.settings }
    var clock: FakeClock { harness.fakes.clock }
    var feature: MediaControlsFeature { harness.feature }

    /// The titles of every HUD so far.
    var hudTitles: [String] { harness.huds.map(\.title) }

    /// The Play or Pause row's live subtitle, as root search holds it.
    func subtitle() throws -> LiveSubtitle {
        try #require(try harness.command(MediaCommandID.playPause).liveSubtitle)
    }

    /// Fetches the subtitle once, as root search does, and returns its text.
    func subtitleText() async throws -> String? {
        await (try subtitle()).value()?.text
    }

    /// Runs a command with errors shown as the host shows them, rather than thrown to the test.
    @discardableResult
    func runShowingErrors(_ id: String, launch: LaunchSource = .root) async throws -> ActionOutcome {
        harness.throwsActionErrors = false
        defer { harness.throwsActionErrors = true }
        return try await harness.run(id, launch: launch)
    }

    // MARK: - Simulated apps

    static let musicPaused: [Player: SimulatedPlayers.App] = [
        .music: playing(SimulatedPlayers.musicQueue, state: .paused, position: 83),
        .spotify: stopped(SimulatedPlayers.spotifyQueue),
    ]

    static let nothingRunning: [Player: SimulatedPlayers.App] = [
        .music: stopped(SimulatedPlayers.musicQueue),
        .spotify: stopped(SimulatedPlayers.spotifyQueue),
    ]

    /// A running app at the first track of its queue.
    static func playing(
        _ queue: [Track], index: Int = 0, state: PlaybackState = .playing, position: Double = 30
    ) -> SimulatedPlayers.App {
        SimulatedPlayers.App(isRunning: true, queue: queue, index: index, state: state, position: position)
    }

    /// An app that is not running.
    static func stopped(_ queue: [Track]) -> SimulatedPlayers.App {
        SimulatedPlayers.App(isRunning: false, queue: queue)
    }
}

/// A player service that counts each look at the players and can hold the asks until a test lets
/// them go, so a test can make two fetches overlap.
nonisolated final class HeldPlayers: PlayerService {
    private struct Watcher {
        var count: Int
        var continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var held = false
        var waiting: [CheckedContinuation<Void, Never>] = []
        var watchers: [Watcher] = []
    }

    private let inner: SimulatedPlayers
    private let state = Mutex(State())

    init(_ inner: SimulatedPlayers) {
        self.inner = inner
    }

    /// From now on, every look at the running players waits until ``release()``.
    func hold() {
        state.withLock { $0.held = true }
    }

    /// Lets every waiting ask go, and asks wait no more.
    func release() {
        let waiting = state.withLock { state in
            state.held = false
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }

    /// How many asks wait now.
    var waitingCount: Int { state.withLock { $0.waiting.count } }

    /// Returns once `count` asks wait. Resumed by the ask that makes the count, never by polling.
    func waitForWaiting(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                guard state.waiting.count < count else { return true }
                state.watchers.append(Watcher(count: count, continuation: continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func runningPlayers() async -> [Player] {
        await withCheckedContinuation { continuation in
            let (resumeNow, satisfied) = state.withLock { state -> (Bool, [Watcher]) in
                guard state.held else { return (true, []) }
                state.waiting.append(continuation)
                let count = state.waiting.count
                let satisfied = state.watchers.filter { $0.count <= count }
                state.watchers.removeAll { $0.count <= count }
                return (false, satisfied)
            }
            for watcher in satisfied { watcher.continuation.resume() }
            if resumeNow { continuation.resume() }
        }
        return await inner.runningPlayers()
    }

    func status(of player: Player) async throws -> NowPlaying {
        try await inner.status(of: player)
    }

    func send(_ transport: Transport, to player: Player) async throws {
        try await inner.send(transport, to: player)
    }
}

extension ActionOutcome {
    /// True for an outcome that closes the panel, with or without a HUD.
    var closesPanel: Bool {
        if case .close = self { return true }
        return false
    }
}
