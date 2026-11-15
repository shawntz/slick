import Foundation
import Kit

/// The Kill Process page: the user's processes with CPU and memory, refreshed while the page is
/// open, with Quit and Force Quit behind a confirmation.
///
/// CPU use needs two samples. The first load shows memory only and asks the host to load again
/// after half a second; from then on the page refreshes at the interval in settings. The host stops
/// refreshing when the page closes, so nothing runs in the background.
final class ProcessList: ListSource {
    /// The delay before the second sample, which is the first with CPU use.
    static let firstRefresh: Duration = .milliseconds(500)

    private let table: any ProcessTable
    private let settings: FeatureSettings
    private let locale: Locale
    /// The last snapshot, to measure CPU use against.
    private var previous: ProcessSnapshot?
    /// This app's PID from the last snapshot. Actions refuse it.
    private var ownPID: Int32 = 0
    /// Sent after Quit or Force Quit, so the page lists the processes again.
    let changes: ChangeSignal? = ChangeSignal()

    init(table: any ProcessTable, settings: FeatureSettings, locale: Locale) {
        self.table = table
        self.settings = settings
        self.locale = locale
    }

    /// Showing background processes changes which rows exist, and the interval changes the next
    /// refresh, so an open page follows both.
    var reloadsOnSettings: [AnySettingKey] {
        [SystemSettings.showsBackgroundProcesses.erased, SystemSettings.processRefresh.erased]
    }

    /// The sort dropdown. It opens on the order chosen in settings.
    var dropdown: FilterDropdown {
        FilterDropdown(
            title: Strings.Processes.sortTitle,
            options: ProcessSort.allCases.map {
                FilterOption(id: $0.rawValue, title: Strings.Processes.sortOption($0))
            },
            defaultID: settings[SystemSettings.processSort].rawValue, remembersSelection: false)
    }

    func load(_ request: ListRequest) async throws -> ListResult {
        let snapshot = try await table.snapshot()
        try Task.checkCancellation()
        let sort = request.filter.flatMap(ProcessSort.init(rawValue:)) ?? settings[SystemSettings.processSort]
        let rows = await ProcessRows.rows(
            snapshot, previous: previous, sort: sort,
            showsBackground: settings[SystemSettings.showsBackgroundProcesses],
            locale: locale)
        try Task.checkCancellation()
        let isFirst = previous == nil
        previous = snapshot
        ownPID = snapshot.ownPID
        return ListResult(
            sections: [ListSection(Strings.Processes.section, id: "processes", showsCount: true, rows: rows)],
            refreshAfter: isFirst ? Self.firstRefresh : settings[SystemSettings.processRefresh].interval)
    }

    /// Built from the row's payload alone. A protected process gets no actions, even if a row for
    /// one were handed back.
    func actions(for row: Row) -> [Action] {
        guard let process = try? row.payload?.decode(ProcessIdentity.self) else { return [] }
        guard !ProcessPolicy.isProtected(process, ownPID: ownPID) else { return [refreshAction] }
        var actions = [quitAction(process), forceQuitAction(process)]
        actions.append(
            .copy(
                String(process.pid), title: Strings.Processes.copyPID, hud: Strings.Processes.copiedPID,
                shortcut: .copy
            ).with(id: "copy-pid"))
        if let path = process.bundlePath ?? process.path {
            actions.append(.reveal([URL(filePath: path)]))
        }
        actions.append(refreshAction)
        return actions
    }

    static let forceQuitShortcut = KeyCombo(.q, [.control, .option, .shift])

    private func quitAction(_ process: ProcessIdentity) -> Action {
        let table = table
        return Action(
            Strings.Processes.quit, id: "quit", icon: .symbol("xmark.circle"),
            confirmation: Confirmation(
                Strings.Processes.quitQuestion(process.name),
                message: Strings.Processes.quitMessage(isApplication: process.isApplication),
                confirmTitle: Strings.Processes.quitConfirm)
        ) { context in
            try await SystemFailure.handle(Strings.Processes.words(quitting: process.name)) {
                try await table.quit(process)
                self.changes?.send()
                context.showToast(.success(Strings.Processes.askedToQuit(process.name)))
                return .keepOpen
            }
        }
    }

    private func forceQuitAction(_ process: ProcessIdentity) -> Action {
        let table = table
        return Action(
            Strings.Processes.forceQuit, id: "force-quit", icon: .symbol("xmark.octagon"),
            shortcut: Self.forceQuitShortcut, style: .destructive,
            confirmation: Confirmation(
                Strings.Processes.forceQuitQuestion(process.name),
                message: Strings.Processes.forceQuitMessage(process.name),
                confirmTitle: Strings.Processes.forceQuitConfirm, isDestructive: true)
        ) { context in
            try await SystemFailure.handle(Strings.Processes.words(quitting: process.name)) {
                try await table.forceQuit(process)
                self.changes?.send()
                context.showToast(.success(Strings.Processes.forcedToQuit(process.name)))
                return .keepOpen
            }
        }
    }

    private var refreshAction: Action {
        Action(Strings.Processes.refresh, id: "refresh", icon: .symbol("arrow.clockwise"), shortcut: .refresh) {
            context in
            context.reload()
            return .keepOpen
        }
    }
}
