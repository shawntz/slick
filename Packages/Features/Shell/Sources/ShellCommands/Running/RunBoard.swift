import Foundation
import Kit

/// The feature's runs: the ones going on, and the last few that ended, whose output a page can
/// still show. Starting a run reads the settings, and a run that ends is saved in the history
/// unless it is hidden or history is off.
final class RunBoard {
    /// How many ended runs keep their output in memory, so Show Output still works after the page
    /// was left. Each keeps at most the output limit.
    static let keptEndedRuns = 3

    /// Runs going on, newest first.
    private(set) var running: [ShellRun] = []
    /// Runs that ended, newest first, at most ``keptEndedRuns``.
    private(set) var recent: [ShellRun] = []
    /// Sent when a run starts or ends, so Shell History shows it.
    let changes: ChangeSignal

    private let context: FeatureContext
    private let processes: any ProcessService
    private let system: any ShellSystem
    private let history: ShellHistory
    private let handOff: HandOff
    /// How many times every run was stopped. A run that started its setup before a stop never starts.
    private var stops = 0

    init(
        context: FeatureContext, processes: any ProcessService, system: any ShellSystem, history: ShellHistory,
        handOff: HandOff, changes: ChangeSignal
    ) {
        self.handOff = handOff
        self.context = context
        self.processes = processes
        self.system = system
        self.history = history
        self.changes = changes
    }

    /// The setup the settings ask for now. Throws what to change when the shell or the folder is
    /// not there.
    func setup() async throws -> RunSetup {
        try await RunSetup.resolve(settings: context.settings, home: context.storage.homeDirectory, system: system)
    }

    /// Starts a command. `reporter` is the context of the action that started it, which reports the
    /// result when no page shows the run.
    ///
    /// The setup reads the Mac off the main thread, so the feature may be turned off meanwhile. A run
    /// whose task was cancelled, or that was still in its setup when every run was stopped, throws
    /// `CancellationError` and never starts its process.
    func start(_ command: ShellCommand, reporter: ActionContext?) async throws -> ShellRun {
        let stopsBefore = stops
        let setup = try await setup()
        try Task.checkCancellation()
        guard stops == stopsBefore else { throw CancellationError() }
        let run = ShellRun(command: command, setup: setup, clock: context.clock, reporter: reporter)
        run.onEnd = { [weak self] run in await self?.ended(run) }
        run.board = self
        running.insert(run, at: 0)
        run.start(processes)
        changes.send()
        return run
    }

    /// The page that shows a run.
    func page(for run: ShellRun) -> Page {
        RunPage(run: run, board: self, handOff: handOff).page()
    }

    /// A run that goes on or ended lately.
    func run(_ id: UUID) -> ShellRun? {
        running.first { $0.id == id } ?? recent.first { $0.id == id }
    }

    /// Stops every run, as when the feature is turned off. A run still in its setup never starts.
    func stopAll() {
        stops += 1
        for run in running {
            run.stop()
        }
    }

    /// Moves an ended run to the recent ones and saves it in the history.
    private func ended(_ run: ShellRun) async {
        running.removeAll { $0 === run }
        recent.insert(run, at: 0)
        if recent.count > Self.keptEndedRuns { recent.removeLast(recent.count - Self.keptEndedRuns) }
        if !run.command.isHidden, let entry = HistoryEntry(run) {
            await history.record(entry)
        }
        changes.send()
    }
}
