import Foundation
import Kit

/// One run of one command. It belongs to the feature, not to a page: closing the panel, leaving the
/// page or the host's return to root search leave it running. Stop, turning the feature off and the
/// end of the process end it.
///
/// A task off the main thread reads the process and appends to ``output``. When the run ends, the
/// metadata shows the status and the run time, the board records it, and the user hears of it unless
/// a page shows the run in the open panel: a HUD while the panel is closed, a toast while it is open
/// on another page.
final class ShellRun {
    let id: UUID
    let command: ShellCommand
    let setup: RunSetup
    let startedAt: Date
    let output: RunOutput
    /// Nil while the run goes on.
    private(set) var ending: RunEnding?
    private(set) var endedAt: Date?
    /// Called once when the run ended, before its pages' streams finish.
    var onEnd: (@MainActor (ShellRun) async -> Void)?
    /// The board that started the run, which makes the page for the Show Output button of the toast
    /// that reports its end.
    weak var board: RunBoard?

    private var facts: RunFacts
    private let clock: any ClockService
    /// The context of the action that started the run, to report the result after its handler
    /// returned. The host shows its toasts as HUDs while the panel is closed.
    private let reporter: ActionContext?
    private var reading: Task<RunEnding, Never>?
    private var pages: [WeakPage] = []
    private var endWaiters: [CheckedContinuation<Void, Never>] = []
    /// True once ``finish(_:)`` has done everything.
    private var isSettled = false

    init(command: ShellCommand, setup: RunSetup, clock: any ClockService, reporter: ActionContext?) {
        id = UUID()
        self.command = command
        self.setup = setup
        self.clock = clock
        self.reporter = reporter
        startedAt = clock.now
        facts = RunFacts(command: command, setup: setup, startedAt: startedAt, locale: clock.locale)
        output = RunOutput(limit: setup.outputLimit.bytes, facts: facts)
    }

    var isRunning: Bool { ending == nil }

    /// Starts the shell and reads it until it ends.
    func start(_ processes: any ProcessService) {
        guard reading == nil else { return }
        let events = processes.textStream(setup.request(for: command))
        let output = self.output
        let reading = Task { await Self.read(events, into: output) }
        self.reading = reading
        // A task of its own, so stopping the reader never cancels the bookkeeping after it.
        Task {
            let ending = await reading.value
            await finish(ending)
        }
    }

    /// Asks the shell to end. Kit's process service sends SIGTERM when the reader stops listening,
    /// and SIGKILL two seconds later if the shell is still there.
    func stop() {
        reading?.cancel()
    }

    // MARK: Pages

    /// A page started showing the run.
    func attach(_ page: RunPage) {
        pages.removeAll { $0.page == nil || $0.page === page }
        pages.append(WeakPage(page))
    }

    /// Returns once the run has ended and its pages heard of it.
    func waitUntilEnded() async {
        guard !isSettled else { return }
        await withCheckedContinuation { endWaiters.append($0) }
    }

    /// True when a page shows this run in the open panel, so the user sees it end.
    var isWatched: Bool {
        pages.contains { $0.page?.isShowing(self) == true }
    }

    // MARK: Ending

    private func finish(_ ending: RunEnding) async {
        let now = clock.now
        self.ending = ending
        endedAt = now
        facts.ending = ending
        facts.runTime = max(0, now.timeIntervalSince(startedAt))
        output.update(facts)
        await onEnd?(self)
        if var toast = Self.report(for: ending), !isWatched {
            if let board {
                toast.action = ToastAction(Strings.Actions.showOutput) { [self] _ in .push(board.page(for: self)) }
            }
            reporter?.showToast(toast)
        }
        output.finish()
        for page in pages {
            page.page?.runDidEnd(self)
        }
        isSettled = true
        let waiters = endWaiters
        endWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// What the user hears when a run ends while no page shows it: nothing when they stopped it.
    nonisolated static func report(for ending: RunEnding) -> Toast? {
        switch ending {
        case .exit(0): .success(Strings.Reports.finished)
        case .exit(let code): .failure(Strings.Reports.exited(code))
        case .couldNotStart: .failure(Strings.Reports.couldNotStart)
        case .stopped: nil
        }
    }

    /// Reads the process off the main thread until it ends, and says how it ended. Standard output
    /// and standard error go into one buffer in the order they arrive.
    @concurrent private static func read(
        _ events: AsyncThrowingStream<ProcessTextEvent, any Error>, into output: RunOutput
    ) async -> RunEnding {
        var status: Int32?
        do {
            for try await event in events {
                switch event {
                case .stdout(let text), .stderr(let text): output.append(text)
                case .exit(let code): status = code
                }
            }
        } catch ProcessError.launchFailed(let reason) {
            return .couldNotStart(DisplayText.oneLine(reason))
        } catch {
            // Stopped: the stream ends with cancellation. A status that came first still counts.
            return status.map(RunEnding.exit) ?? .stopped
        }
        return status.map(RunEnding.exit) ?? .stopped
    }
}

/// A page the run does not keep alive.
private struct WeakPage {
    weak var page: RunPage?

    init(_ page: RunPage) {
        self.page = page
    }
}
