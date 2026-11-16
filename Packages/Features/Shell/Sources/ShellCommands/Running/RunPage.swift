import Foundation
import Kit

/// The page that shows a run: its output as it arrives, monospaced with its ANSI colors, and its
/// metadata, which gives the exit status and the run time when it ends.
///
/// The page is a view onto the run. Leaving it, or closing the panel, leaves the run going; the page
/// keeps track of whether the panel shows it, so the run knows whether the user saw it end.
final class RunPage: DetailSource, PageEvents {
    private(set) var run: ShellRun
    private let board: RunBoard
    private let handOff: HandOff
    let actionsChanged: ChangeSignal? = ChangeSignal()
    /// True after the panel closed with this page in it, until it shows again.
    private(set) var isPanelHidden = false
    /// This page's stream on its run's output, while attached.
    private var watcher: Int?

    init(run: ShellRun, board: RunBoard, handOff: HandOff) {
        self.run = run
        self.board = board
        self.handOff = handOff
    }

    /// The page, titled by its command.
    func page() -> Page {
        .detail(DetailPage(title: Strings.Page.title(run.command.trimmed), source: self))
    }

    /// The run's output as the host pulls it: the detail as it stands, then everything that changed
    /// since the host's last pull, as one update each time. A run that already ended shows its final
    /// detail once.
    func start() -> AsyncThrowingStream<DetailUpdate, any Error> {
        let output = run.output
        guard let id = output.attach() else {
            watcher = nil
            let detail = output.detail
            return AsyncThrowingStream { continuation in
                continuation.yield(.replace(detail))
                continuation.finish()
            }
        }
        watcher = id
        run.attach(self)
        // Stop replaces Run Again when the page starts again on a new run.
        actionsChanged?.send()
        let lease = OutputLease(output: output, id: id)
        return AsyncThrowingStream(unfolding: { await lease.next() })
    }

    /// The run ended: Run Again replaces Stop.
    func runDidEnd(_ run: ShellRun) {
        guard run === self.run else { return }
        actionsChanged?.send()
    }

    /// True when the page shows this run in the open panel.
    func isShowing(_ run: ShellRun) -> Bool {
        guard run === self.run, !isPanelHidden, let watcher else { return false }
        return run.output.isAttached(watcher)
    }

    // MARK: PageEvents

    func panelDidClose() {
        isPanelHidden = true
    }

    func pageWillShowAgain(_ reason: PageShowReason) {
        isPanelHidden = false
    }

    // MARK: Actions

    /// With output: Copy Output, Paste Output, Stop or Run Again, Copy Command, Open in Terminal.
    /// Without output, Copy Command comes first, so Return on an empty page never stops or runs.
    func actions(for detail: Detail) -> [Action] {
        let run = self.run
        let control = run.isRunning ? stopAction(run) : runAgainAction()
        let copyCommand = Action.copy(
            run.command.trimmed, title: Strings.Actions.copyCommand, hud: Strings.Actions.copiedCommand
        ).with(id: "copy-command")
        let terminal = Action.runCommand(
            ShellFeature.terminalCommandID, title: Strings.Actions.openInTerminal, icon: .symbol("apple.terminal"),
            arguments: handOff.arguments(for: run.command.text)
        ).with(id: "open-in-terminal")
        guard !run.output.isEmpty else { return [copyCommand, control, terminal] }
        return [copyOutputAction(run.output), pasteOutputAction(run.output), control, copyCommand, terminal]
    }

    private func copyOutputAction(_ output: RunOutput) -> Action {
        Action.copy(title: Strings.Actions.copyOutput, hud: Strings.Actions.copiedOutput, shortcut: .copy) { _ in
            .text(try await Self.plainOutput(output))
        }.with(id: "copy-output")
    }

    private func pasteOutputAction(_ output: RunOutput) -> Action {
        Action.paste(title: Strings.Actions.pasteOutput) { _ in
            .text(try await Self.plainOutput(output))
        }.with(id: "paste-output")
    }

    private func stopAction(_ run: ShellRun) -> Action {
        Action(Strings.Actions.stop, id: "stop", icon: .symbol("stop.fill"), shortcut: KeyCombo(.c, .control)) { _ in
            run.stop()
            return .keepOpen
        }
    }

    /// Runs the same command again in this page, with the settings as they are now.
    private func runAgainAction() -> Action {
        Action(
            Strings.Actions.runAgain, id: "run-again", icon: .symbol("arrow.clockwise"), shortcut: .refresh,
            runPolicy: .dropWhileRunning
        ) { [weak self] context in
            guard let self else { return .keepOpen }
            run = try await board.start(run.command, reporter: context)
            context.reload()
            return .keepOpen
        }
    }

    /// The output without escape sequences, made off the main thread. Throws when there is none.
    @concurrent private static func plainOutput(_ output: RunOutput) async throws -> String {
        let text = ANSI.strip(output.text)
        guard !text.isEmpty else { throw ActionFailure(Strings.Actions.noOutput) }
        return text
    }
}
