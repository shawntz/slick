import Kit
import Synchronization

/// Players that exist only in memory, each with a made-up queue, for scenarios, self-tests and
/// tests. Nothing is sent to any app and nothing plays.
///
/// The permission to control a player comes from the run's permission service, so the host's
/// permission card and its grant work as they do in the app: not asked yet reads as
/// ``PlayerFailure/permissionNeeded(_:)``, refused as ``PlayerFailure/permissionDenied(_:)``.
nonisolated final class SimulatedPlayers: PlayerService {
    /// One simulated app.
    struct App: Hashable, Sendable {
        var isRunning: Bool
        var queue: [Track]
        /// Where the player is in ``queue``. Past the end means it has no current track.
        var index: Int
        var state: PlaybackState
        /// Seconds into the current track.
        var position: Double

        init(isRunning: Bool, queue: [Track], index: Int = 0, state: PlaybackState = .paused, position: Double = 0) {
            self.isRunning = isRunning
            self.queue = queue
            self.index = index
            self.state = queue.indices.contains(index) ? state : .stopped
            self.position = position
        }

        var track: Track? { queue.indices.contains(index) ? queue[index] : nil }
    }

    /// What reached a player, in order. A call that failed before it would have sent anything, as
    /// for a player that is not running or may not be controlled, is not recorded, except the
    /// look at which players run, which asks no player anything.
    enum Request: Hashable, Sendable {
        case running
        case status(Player)
        case send(Transport, Player)
    }

    private struct State {
        var apps: [Player: App]
        var requests: [Request] = []
        var failures: [Player: PlayerFailure] = [:]
        /// After a skip, how many status reads still show the track before it, as a player that
        /// takes a moment to load the next track does.
        var lag: [Player: Int] = [:]
        var staleReads: [Player: Int] = [:]
        /// Where the player was before the last skip, which a stale read reports.
        var previous: [Player: (index: Int, position: Double)] = [:]
    }

    private let state: Mutex<State>
    private let permissions: PermissionReader?
    private let settings: FeatureSettings?

    /// - Parameter permissions: Where the permission to control each player is read. Nil grants
    ///   every player.
    init(_ apps: [Player: App], permissions: PermissionReader? = nil, settings: FeatureSettings? = nil) {
        state = Mutex(State(apps: apps))
        self.permissions = permissions
        self.settings = settings
    }

    /// Music running and paused one minute and 23 seconds into the first of three made-up songs.
    /// Spotify is installed but not running.
    /// `settings` lets a scenario quit a player through ``MediaSettings/simulatedQuit``.
    static func sample(permissions: PermissionReader? = nil, settings: FeatureSettings? = nil) -> SimulatedPlayers {
        SimulatedPlayers(
            [
                .music: App(isRunning: true, queue: musicQueue, state: .paused, position: 83),
                .spotify: App(isRunning: false, queue: spotifyQueue),
            ], permissions: permissions, settings: settings)
    }

    static let musicQueue = [
        Track(title: "Example Song One", artist: "Example Artist", album: "Example Album", duration: 245),
        Track(title: "Example Song Two", artist: "Example Artist", album: "Example Album", duration: 198),
        Track(title: "Example Song Three", artist: "Example Artist", album: "Example Album", duration: 312),
    ]

    static let spotifyQueue = [
        Track(title: "Sample Track A", artist: "Sample Band", album: "Sample Record", duration: 201),
        Track(title: "Sample Track B", artist: "Sample Band", album: "Sample Record", duration: 176),
    ]

    // MARK: - For tests and scenarios

    /// Every request, in order.
    var requests: [Request] { state.withLock { $0.requests } }

    /// The transport commands that reached a player, in order.
    var sent: [Request] { requests.filter { if case .send = $0 { true } else { false } } }

    /// How many times a player was asked what it does.
    func statusReads(of player: Player) -> Int {
        requests.count { $0 == .status(player) }
    }

    /// The app as it is now.
    func app(_ player: Player) -> App? {
        state.withLock { $0.apps[player] }
    }

    /// Replaces an app, as when the user opens or quits it, or plays something else.
    func set(_ player: Player, _ app: App) {
        state.withLock { $0.apps[player] = app }
    }

    /// Makes every call to the player fail, or work again with nil.
    func fail(_ player: Player, with failure: PlayerFailure?) {
        state.withLock { $0.failures[player] = failure }
    }

    /// After each skip, the next `reads` status reads still show the track before it.
    func setLag(_ player: Player, reads: Int) {
        state.withLock { $0.lag[player] = reads }
    }

    // MARK: - PlayerService

    func runningPlayers() async -> [Player] {
        let quit = quitPlayers
        return state.withLock { state in
            state.requests.append(.running)
            return Player.allCases.filter { state.apps[$0]?.isRunning == true && !quit.contains($0) }
        }
    }

    /// The players a scenario quit through ``MediaSettings/simulatedQuit``.
    private var quitPlayers: Set<Player> {
        guard let text = settings?[MediaSettings.simulatedQuit], !text.isEmpty else { return [] }
        let ids = Set(text.split(separator: ",").map(String.init))
        return Set(Player.allCases.filter { ids.contains($0.bundleID) })
    }

    func status(of player: Player) async throws -> NowPlaying {
        let permission = permissionFailure(for: player)
        let quit = quitPlayers.contains(player)
        return try state.withLock { state in
            let app = try Self.reachable(player, in: state, permission: permission, quit: quit)
            state.requests.append(.status(player))
            var (index, position) = (app.index, app.position)
            if let stale = state.staleReads[player], stale > 0, let previous = state.previous[player] {
                state.staleReads[player] = stale - 1
                (index, position) = previous
            }
            let track = app.queue.indices.contains(index) ? app.queue[index] : nil
            return NowPlaying(
                player: player, state: track == nil ? .stopped : app.state, track: track,
                position: track == nil ? nil : position)
        }
    }

    func send(_ transport: Transport, to player: Player) async throws {
        let permission = permissionFailure(for: player)
        let quit = quitPlayers.contains(player)
        try state.withLock { state in
            var app = try Self.reachable(player, in: state, permission: permission, quit: quit)
            state.requests.append(.send(transport, player))
            switch transport {
            case .playPause:
                if app.state == .playing {
                    app.state = .paused
                } else if app.track != nil {
                    app.state = .playing
                }
            case .pause:
                if app.state == .playing { app.state = .paused }
            case .next, .previous:
                state.previous[player] = (app.index, app.position)
                state.staleReads[player] = state.lag[player] ?? 0
                let step = transport == .next ? 1 : -1
                app.index = min(app.queue.count, max(0, app.index + step))
                app.position = 0
                if app.track == nil {
                    app.state = .stopped
                } else if app.state == .stopped {
                    app.state = .paused
                }
            }
            state.apps[player] = app
        }
    }

    /// The app, when it runs and may be controlled. Throws as the live service would.
    private static func reachable(
        _ player: Player, in state: State, permission: PlayerFailure?, quit: Bool = false
    ) throws -> App {
        guard let app = state.apps[player], app.isRunning, !quit else { throw PlayerFailure.notRunning(player) }
        if let permission { throw permission }
        if let failure = state.failures[player] { throw failure }
        return app
    }

    private func permissionFailure(for player: Player) -> PlayerFailure? {
        switch permissions?.status(of: player.permission) ?? .granted {
        case .granted: nil
        case .notDetermined: .permissionNeeded(player)
        case .denied, .restricted: .permissionDenied(player)
        }
    }
}
