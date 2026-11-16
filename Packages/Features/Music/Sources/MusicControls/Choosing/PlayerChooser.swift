/// The player a command acts on, and what it was doing when chosen.
nonisolated enum PlayerChoice: Hashable, Sendable {
    /// No player runs.
    case none
    /// This player, as it was when read.
    case player(NowPlaying)
    /// A running player could not be read, and no other one is known to play. Often its
    /// permission is missing.
    case failure(PlayerFailure)
}

/// Picks the player, by one rule for every command and for the live subtitle.
///
/// Only running players are candidates, so no event ever goes to a player that is not running.
/// Each candidate is asked what it does, the preferred player first:
///
/// 1. A player that plays wins. When both play, the preferred one.
/// 2. Otherwise, a player whose permission was never asked stops the choice: it may be the one
///    that plays, and only the host's card may ask. A player the user refused is left out.
/// 3. Otherwise, the first player that answered, so the preferred one when it answered.
/// 4. Otherwise, the first failure. A player that quit while it was asked counts as not running.
nonisolated enum PlayerChooser {
    @concurrent static func choose(using players: any PlayerService, preferring preferred: Player) async
        -> PlayerChoice
    {
        let running = await players.runningPlayers()
        var readings: [Result<NowPlaying, PlayerFailure>] = []
        for player in Player.ordered(preferring: preferred) where running.contains(player) {
            do {
                readings.append(.success(try await players.status(of: player)))
            } catch let failure as PlayerFailure {
                readings.append(.failure(failure))
            } catch {
                readings.append(.failure(.failed(player, code: 0)))
            }
        }
        return decide(readings)
    }

    /// The rule, apart from any player. `readings` are in the order the players were asked, the
    /// preferred one first.
    static func decide(_ readings: [Result<NowPlaying, PlayerFailure>]) -> PlayerChoice {
        let answered = readings.compactMap { try? $0.get() }
        let failures = readings.compactMap { reading -> PlayerFailure? in
            guard case .failure(let failure) = reading else { return nil }
            return failure
        }
        if let playing = answered.first(where: \.isPlaying) { return .player(playing) }
        if let unasked = failures.first(where: { $0 == .permissionNeeded($0.player) }) { return .failure(unasked) }
        if let first = answered.first { return .player(first) }
        let stillRunning = failures.filter { $0 != .notRunning($0.player) }
        guard let failure = stillRunning.first else { return .none }
        return .failure(failure)
    }
}
