import Foundation
import Kit
import Synchronization

/// What the Play or Pause row shows under its title, asked of the players at most once every two
/// seconds.
///
/// Root search fetches a live subtitle only while the row is on screen, and stops when the panel
/// closes, so the feature itself runs no timer. Root waits at least ten seconds between its own
/// fetches, but it also fetches at once each time ``changes`` fires, and two fetches can overlap.
/// So the monitor keeps the last answer and when it was asked for:
///
/// - A fetch within two seconds of the last answer gets that answer, and asks nothing.
/// - A fetch while an ask is under way waits for that ask, and asks nothing itself.
/// - A command that just read a player hands its answer over with ``record(_:)``, which counts as
///   an answer, so the row shows the new track without asking the player again.
///
/// An answer comes after its ask began, so two asks always begin at least two seconds apart. The
/// time comes from the feature's clock. A clock set back makes the last answer count as old.
nonisolated final class NowPlayingMonitor: Sendable {
    /// The shortest time between two asks.
    static let interval: Duration = .seconds(2)

    /// Fires when a command learned what a player does, so root search shows it at once.
    let changes = ChangeSignal()

    private struct Memory {
        var choice: PlayerChoice?
        /// When ``choice`` was answered or recorded.
        var answeredAt: Date?
        var running: Task<PlayerChoice, Never>?
        /// Counts answers, so an ask that ends after a newer ``record(_:)`` does not overwrite it.
        var generation = 0
    }

    private let players: any PlayerService
    private let clock: any ClockService
    private let settings: FeatureSettings
    private let memory = Mutex(Memory())

    init(players: any PlayerService, clock: any ClockService, settings: FeatureSettings) {
        self.players = players
        self.clock = clock
        self.settings = settings
    }

    /// The players' state, from the last answer when it is fresh, otherwise asked now.
    @concurrent func current() async -> PlayerChoice {
        enum Plan {
            case known(PlayerChoice)
            case wait(Task<PlayerChoice, Never>)
            case ask(Task<PlayerChoice, Never>, generation: Int)
        }
        let now = clock.now
        let (players, settings) = (players, settings)
        let plan = memory.withLock { memory -> Plan in
            // A fresh answer first: a command may have recorded one while an older ask still runs.
            if let choice = memory.choice, let answeredAt = memory.answeredAt, Self.isFresh(answeredAt, now: now) {
                return .known(choice)
            }
            if let running = memory.running { return .wait(running) }
            let task = Task {
                await PlayerChooser.choose(using: players, preferring: settings[MediaSettings.preferredPlayer])
            }
            memory.running = task
            memory.generation += 1
            return .ask(task, generation: memory.generation)
        }
        switch plan {
        case .known(let choice):
            return choice
        case .wait(let task):
            return await task.value
        case .ask(let task, let generation):
            let choice = await task.value
            let answeredAt = clock.now
            memory.withLock { memory in
                memory.running = nil
                // A command's newer answer stays.
                guard memory.generation == generation else { return }
                memory.choice = choice
                memory.answeredAt = answeredAt
            }
            return choice
        }
    }

    /// Keeps what a command just read, as if the row had asked now, and tells root search.
    func record(_ choice: PlayerChoice) {
        let now = clock.now
        memory.withLock { memory in
            memory.choice = choice
            memory.answeredAt = now
            memory.generation += 1
        }
        changes.send()
    }

    /// True when an answer from `answeredAt` is recent enough at `now`. A time in the clock's
    /// future, as after the clock was set back, is not.
    static func isFresh(_ answeredAt: Date, now: Date) -> Bool {
        let elapsed = now.timeIntervalSince(answeredAt)
        return elapsed >= 0 && elapsed < interval.timeInterval
    }

    /// The row's subtitle for an answer.
    static func subtitle(for choice: PlayerChoice) -> LiveSubtitle.Value {
        switch choice {
        case .none:
            return LiveSubtitle.Value(Strings.Subtitle.noPlayer)
        case .player(let now):
            guard let track = now.track, now.state != .stopped else {
                return LiveSubtitle.Value(Strings.Subtitle.idle(now.player))
            }
            let text =
                now.isPlaying
                ? Strings.Subtitle.playing(track, in: now.player) : Strings.Subtitle.paused(track, in: now.player)
            return LiveSubtitle.Value(text)
        case .failure(let failure):
            switch failure {
            case .permissionNeeded(let player), .permissionDenied(let player):
                return LiveSubtitle.Value(Strings.Subtitle.needsAccess(player))
            case .notRunning:
                return LiveSubtitle.Value(Strings.Subtitle.noPlayer)
            case .timedOut(let player), .failed(let player, _):
                return LiveSubtitle.Value(Strings.Subtitle.silent(player))
            }
        }
    }
}

extension Duration {
    /// The duration in seconds, with fractions.
    nonisolated var timeInterval: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
