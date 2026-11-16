import Foundation
import Kit

/// The Shell History page: commands going on now, then past commands by day, newest first, each
/// with its time, exit status and run time. The host filters by command.
///
/// Return on a past command puts it back in root search behind the prefix, so a second Return runs
/// it: a history row never runs at once. Return on a running command shows its output.
final class HistoryList: ListSource {
    static let runningSectionID = "running"

    private let history: ShellHistory
    private let board: RunBoard
    private let clock: any ClockService
    private let listChanges: ChangeSignal

    init(history: ShellHistory, board: RunBoard, clock: any ClockService, changes: ChangeSignal) {
        self.history = history
        self.board = board
        self.clock = clock
        listChanges = changes
    }

    var changes: ChangeSignal? { listChanges }
    var reloadsOnSettings: [AnySettingKey] { [ShellSettings.keepsHistory.erased] }

    func page() -> Page {
        .list(
            ListPage(
                self, title: Strings.historyCommand, searchPlaceholder: Strings.History.placeholder,
                emptyState: emptyState()))
    }

    func load(_ request: ListRequest) async throws -> ListResult {
        await history.loaded()
        try Task.checkCancellation()
        var sections: [ListSection] = []
        let running = board.running.map { Self.row(for: $0) }
        if !running.isEmpty {
            sections.append(ListSection(Strings.History.runningSection, id: Self.runningSectionID, rows: running))
        }
        let days = DaySections(clock: clock, direction: .past)
        let locale = clock.locale
        sections += days.sections(history.entries, date: \.date) { Self.row(for: $0, locale: locale) }
        return ListResult(sections: sections, emptyState: emptyState())
    }

    func actions(for row: Row) -> [Action] {
        if let entry = try? row.payload?.decode(HistoryEntry.self) {
            return pastActions(entry)
        }
        if let id = try? row.payload?.decode(RunReference.self).id, let run = board.run(id) {
            return runningActions(run)
        }
        return []
    }

    private func emptyState() -> EmptyState {
        history.isEnabled
            ? EmptyState(
                icon: .symbol("clock.arrow.circlepath"), title: Strings.History.emptyTitle,
                message: Strings.History.emptyMessage)
            : EmptyState(
                icon: .symbol("clock.arrow.circlepath"), title: Strings.History.offTitle,
                message: Strings.History.offMessage)
    }

    // MARK: Rows

    /// A command going on now.
    static func row(for run: ShellRun) -> Row {
        Row(
            id: ItemID(ShellFeature.namespace, "run." + run.id.uuidString),
            title: DisplayText.oneLine(run.command.trimmed), icon: .symbol("terminal"),
            accessories: [.tag(Strings.History.runningTag, color: .blue), .date(run.startedAt)],
            payload: Payload(RunReference(id: run.id)), memory: .never)
    }

    /// A past command: the command as title, with its exit status, run time and start.
    nonisolated static func row(for entry: HistoryEntry, locale: Locale) -> Row {
        let status: Accessory =
            switch (entry.exitStatus, entry.stopped) {
            case (0, _): .tag(Strings.History.exitTag(0), color: .green)
            case (let code?, _): .tag(Strings.History.exitTag(code), color: .red)
            case (nil, true): .tag(Strings.History.stoppedTag)
            case (nil, false): .tag(Strings.History.notStartedTag, color: .red)
            }
        return Row(
            id: ItemID(ShellFeature.namespace, "history." + entry.id.uuidString),
            title: DisplayText.oneLine(entry.command), icon: .symbol("terminal"),
            accessories: [status, .text(Strings.duration(entry.duration, locale: locale)), .date(entry.date)],
            payload: Payload(entry), memory: .never)
    }

    // MARK: Actions

    /// Use Again, then Show Output while the run's output is still in memory, Copy Command, Delete
    /// and Clear History.
    private func pastActions(_ entry: HistoryEntry) -> [Action] {
        let history = self.history
        var actions: [Action] = [
            Action(Strings.Actions.useAgain, id: "use-again", icon: .symbol("magnifyingglass")) { _ in
                guard case .success(let command) = ShellCommand.check(entry.command) else {
                    throw ActionFailure(Strings.Failures.cannotRun)
                }
                return .showRoot(query: RootQuery.query(for: command))
            }
        ]
        if let run = board.run(entry.id) {
            actions.append(showOutputAction(run))
        }
        actions.append(
            Action.copy(entry.command, title: Strings.Actions.copyCommand, hud: Strings.Actions.copiedCommand)
                .with(id: "copy-command").with(shortcut: .copy))
        actions.append(
            Action(
                Strings.Actions.delete, id: "delete", icon: .symbol("trash"), shortcut: .remove, style: .destructive
            ) { context in
                await history.delete(entry.id)
                context.showToast(.success(Strings.Actions.deleted))
                return .keepOpen
            })
        actions.append(clearAction())
        return actions
    }

    /// Show Output, Stop and Copy Command for a command going on now.
    private func runningActions(_ run: ShellRun) -> [Action] {
        var actions = [showOutputAction(run)]
        if run.isRunning {
            actions.append(
                Action(Strings.Actions.stop, id: "stop", icon: .symbol("stop.fill"), shortcut: KeyCombo(.c, .control)) {
                    context in
                    run.stop()
                    context.showToast(.success(Strings.Actions.stopping))
                    return .keepOpen
                })
        }
        actions.append(
            Action.copy(run.command.trimmed, title: Strings.Actions.copyCommand, hud: Strings.Actions.copiedCommand)
                .with(id: "copy-command").with(shortcut: .copy))
        return actions
    }

    private func showOutputAction(_ run: ShellRun) -> Action {
        let board = self.board
        return .push(Strings.Actions.showOutput, id: "show-output", icon: .symbol("text.alignleft")) {
            board.page(for: run)
        }
    }

    /// Deletes every saved command after asking.
    func clearAction() -> Action {
        let history = self.history
        return Action(
            Strings.Actions.clearHistory, id: "clear-history", icon: .symbol("trash.slash"), shortcut: .removeAll,
            style: .destructive, confirmation: Self.clearConfirmation
        ) { context in
            await history.clear()
            context.showToast(.success(Strings.Actions.cleared))
            return .keepOpen
        }
    }

    static let clearConfirmation = Confirmation(
        Strings.Actions.clearQuestion, message: Strings.Actions.clearMessage,
        confirmTitle: Strings.Actions.clearConfirm,
        isDestructive: true)
}

/// The payload of a running command's row: the run's ID.
nonisolated struct RunReference: Codable, Hashable, Sendable {
    var id: UUID
}
