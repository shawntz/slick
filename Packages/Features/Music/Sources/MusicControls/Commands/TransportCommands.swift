import Kit

/// Play or Pause, Pause, Next Track, Previous Track and Now Playing.
///
/// Each command picks the player with ``PlayerChooser``, so it acts only on a player that runs.
/// When no player runs, it asks whether to open the preferred one, except Pause, which has nothing
/// to pause and says so. Pause sends its event only to a player that plays, so it never starts
/// one. When the player may not be
/// controlled yet, it returns `.needsPermission`, and the host shows its card. Otherwise the panel
/// closes, the command reaches the player, and a HUD says what the player does now.
///
/// Runs are serial, the Kit default, so a second press of Next Track starts from the track the
/// first one reached. None of them pastes or changes data, so each may run from a deep link after
/// the host's page that asks.
extension MediaControlsFeature {
    /// How many times a skip reads the player again when it still reports the old track.
    static let skipChecks = 5
    /// The wait between those reads.
    static let skipWait: Duration = .milliseconds(150)

    var playPauseCommand: Command {
        let monitor = monitor
        return Command(
            id: MediaCommandID.playPause, title: Strings.Commands.playPause, icon: .symbol("playpause"),
            keywords: Strings.Commands.playPauseKeywords,
            liveSubtitle: .background(every: NowPlayingMonitor.interval, changes: monitor.changes) {
                NowPlayingMonitor.subtitle(for: await monitor.current())
            }
        ) { context in
            try await self.run(.playPause, context: context)
        }
    }

    var pauseCommand: Command {
        Command(
            id: MediaCommandID.pause, title: Strings.Commands.pause, icon: .symbol("pause"),
            keywords: Strings.Commands.pauseKeywords
        ) { context in
            try await self.pause(context: context)
        }
    }

    var nextCommand: Command {
        Command(
            id: MediaCommandID.next, title: Strings.Commands.next, icon: .symbol("forward.end"),
            keywords: Strings.Commands.nextKeywords
        ) { context in
            try await self.run(.next, context: context)
        }
    }

    var previousCommand: Command {
        Command(
            id: MediaCommandID.previous, title: Strings.Commands.previous, icon: .symbol("backward.end"),
            keywords: Strings.Commands.previousKeywords
        ) { context in
            try await self.run(.previous, context: context)
        }
    }

    var nowPlayingCommand: Command {
        Command(
            id: MediaCommandID.nowPlaying, title: Strings.Commands.nowPlaying, icon: .symbol("music.note"),
            keywords: Strings.Commands.nowPlayingKeywords
        ) { context in
            try await self.showNowPlaying(context: context)
        }
    }

    // MARK: - Running

    /// Picks the player, sends the command, and says what the player does after it.
    func run(_ transport: Transport, context: ActionContext) async throws -> ActionOutcome {
        let preferred = context.settings[MediaSettings.preferredPlayer]
        let choice = await PlayerChooser.choose(using: players, preferring: preferred)
        monitor.record(choice)
        let before: NowPlaying
        switch choice {
        case .none:
            return try await offerToOpen(preferred, context: context)
        case .failure(let failure):
            return try Self.outcome(for: failure)
        case .player(let now):
            before = now
        }
        // Asking the players takes a moment. A run cancelled meanwhile, as when the feature was
        // turned off, sends nothing.
        try Task.checkCancellation()
        // The player runs and may be controlled, so nothing below needs the panel.
        context.dismiss()
        do {
            try await players.send(transport, to: before.player)
            let after = try await read(after: transport, from: before, clock: context.clock)
            monitor.record(.player(after))
            return .close(hud: HUD(Strings.done(transport, now: after)))
        } catch let failure as PlayerFailure {
            return try Self.outcome(for: failure)
        }
    }

    /// Pauses the player that plays. A player that does not play gets nothing, and the HUD says
    /// so, so typing "pause" never starts one.
    func pause(context: ActionContext) async throws -> ActionOutcome {
        let preferred = context.settings[MediaSettings.preferredPlayer]
        let choice = await PlayerChooser.choose(using: players, preferring: preferred)
        monitor.record(choice)
        switch choice {
        case .none:
            return .close(hud: HUD(Strings.notPlaying))
        case .failure(let failure):
            return try Self.outcome(for: failure)
        case .player(let now) where !now.isPlaying:
            return .close(hud: HUD(Strings.notPlaying(now)))
        case .player:
            return try await run(.pause, context: context)
        }
    }

    /// Picks the player as the transport commands do, and shows what it plays.
    func showNowPlaying(context: ActionContext) async throws -> ActionOutcome {
        let preferred = context.settings[MediaSettings.preferredPlayer]
        let choice = await PlayerChooser.choose(using: players, preferring: preferred)
        monitor.record(choice)
        switch choice {
        case .none:
            return try await offerToOpen(preferred, context: context)
        case .failure(let failure):
            return try Self.outcome(for: failure)
        case .player(let now):
            return .close(hud: HUD(Strings.nowPlaying(now)))
        }
    }

    /// What the player does once the command ran. A player can report the old track for a moment
    /// after a skip, so a skip reads again, a few times and briefly apart, until the track or the
    /// position shows that it moved. A skip that lands on the same track, as at the start of a
    /// queue, reports after the last read.
    func read(after transport: Transport, from before: NowPlaying, clock: any ClockService) async throws -> NowPlaying {
        var after = try await players.status(of: before.player)
        guard transport.skips, before.track != nil else { return after }
        var checks = 0
        while checks < Self.skipChecks, !Self.hasMoved(from: before, to: after) {
            checks += 1
            try await clock.sleep(for: Self.skipWait)
            after = try await players.status(of: before.player)
        }
        return after
    }

    /// True when a skip shows: another track, no track, or a position at least a second earlier.
    nonisolated static func hasMoved(from before: NowPlaying, to after: NowPlaying) -> Bool {
        guard after.track == before.track else { return true }
        guard let was = before.position, let now = after.position else { return false }
        return now < was - 1
    }

    /// Asks whether to open the preferred player, and opens it only when the user says so.
    private func offerToOpen(_ player: Player, context: ActionContext) async throws -> ActionOutcome {
        let question = Confirmation(
            Strings.Open.question(player), message: Strings.Open.message(player),
            confirmTitle: Strings.Open.confirm(player))
        guard await context.confirm(question) else { return .keepOpen }
        // The question may have waited long. A run cancelled meanwhile opens nothing.
        try Task.checkCancellation()
        do {
            try await context.workspace.launch(bundleID: player.bundleID)
        } catch {
            throw ActionFailure(Strings.Open.failed(player), message: Strings.Open.failedMessage(player))
        }
        return .close(hud: HUD(Strings.Open.opened(player)))
    }

    /// The permission card for a missing permission, otherwise a failure in the feature's words.
    static func outcome(for failure: PlayerFailure) throws -> ActionOutcome {
        switch failure {
        case .permissionNeeded(let player), .permissionDenied(let player):
            return .needsPermission(player.permission)
        case .notRunning(let player):
            throw ActionFailure(Strings.Failure.notRunning(player), message: Strings.Failure.notRunningMessage)
        case .timedOut(let player):
            throw ActionFailure(Strings.Failure.timedOut(player), message: Strings.Failure.timedOutMessage)
        case .failed(let player, let code):
            throw ActionFailure(Strings.Failure.failed(player), message: Strings.Failure.code(code))
        }
    }
}
