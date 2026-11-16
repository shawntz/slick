import Kit

/// Why a player did not answer or act.
nonisolated enum PlayerFailure: Error, Hashable, Sendable {
    /// The player is not running, or quit before the event reached it.
    case notRunning(Player)
    /// The user has not answered whether the launcher may control the player. Sending now would
    /// show the system's prompt, so nothing was sent.
    case permissionNeeded(Player)
    /// The user refused it, or a profile does. Nothing was sent.
    case permissionDenied(Player)
    /// The player did not answer in time.
    case timedOut(Player)
    /// The player or macOS returned this error.
    case failed(Player, code: Int32)

    var player: Player {
        switch self {
        case .notRunning(let player), .permissionNeeded(let player), .permissionDenied(let player),
            .timedOut(let player), .failed(let player, _):
            player
        }
    }

    /// True when the failure is about the permission to control the player.
    var isPermission: Bool {
        switch self {
        case .permissionNeeded, .permissionDenied: true
        default: false
        }
    }
}

/// Music and Spotify, as the feature drives them. It lives in this package because no other
/// feature needs it.
///
/// The live implementation finds running players without any permission and sends Apple Events
/// only to a player that runs, so it never starts one. It checks the Automation permission before
/// every event without asking, so the system prompt only ever follows the user's press of Grant on
/// the host's card. Tests, scenarios, self-tests and benchmarks get ``SimulatedPlayers``, which
/// plays a made-up queue.
///
/// Every requirement is `@concurrent`, so the work runs off the main thread whoever calls it.
nonisolated protocol PlayerService: Sendable {
    /// The players that run now, in ``Player`` declaration order. Asks no player anything and needs
    /// no permission.
    @concurrent func runningPlayers() async -> [Player]

    /// What the player does now. Throws ``PlayerFailure``; ``PlayerFailure/notRunning(_:)`` when it
    /// does not run, without sending anything.
    @concurrent func status(of player: Player) async throws -> NowPlaying

    /// Sends one transport command. Throws ``PlayerFailure``; ``PlayerFailure/notRunning(_:)`` when
    /// the player does not run, without sending anything.
    @concurrent func send(_ transport: Transport, to player: Player) async throws
}

/// The player service for each kind of run.
nonisolated enum PlayerServiceKey: FeatureServiceKey {
    static func live(_ context: FeatureContext) -> any PlayerService {
        LivePlayers()
    }

    static func isolated(_ context: FeatureContext) -> any PlayerService {
        SimulatedPlayers.sample(permissions: context.permissions, settings: context.settings)
    }
}
