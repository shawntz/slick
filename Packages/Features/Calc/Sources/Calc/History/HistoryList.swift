import Foundation
import Kit

/// The Calculator History page: saved answers by day, newest first, filtered by the host.
final class HistoryList: ListSource {
    private let history: CalcHistory
    private let actionsMaker: CalcActions
    private let clock: any ClockService

    init(history: CalcHistory, actions: CalcActions, clock: any ClockService) {
        self.history = history
        self.actionsMaker = actions
        self.clock = clock
    }

    var changes: ChangeSignal? { history.changes }
    var reloadsOnSettings: [AnySettingKey] { [CalcSettings.keepsHistory.erased] }

    func page() -> Page {
        .list(
            ListPage(
                self, title: CalcStrings.historyCommand, searchPlaceholder: CalcStrings.historyPlaceholder,
                emptyState: emptyState()))
    }

    func load(_ request: ListRequest) async throws -> ListResult {
        await history.loaded()
        let entries = history.entries
        let days = DaySections(clock: clock, direction: .past)
        let sections = days.sections(entries, date: \.date) { Self.row(for: $0) }
        return ListResult(sections: sections, emptyState: emptyState())
    }

    func actions(for row: Row) -> [Action] {
        actionsMaker.forHistory(row)
    }

    private func emptyState() -> EmptyState {
        history.isEnabled
            ? EmptyState(
                icon: .symbol("clock.arrow.circlepath"), title: CalcStrings.emptyHistoryTitle,
                message: CalcStrings.emptyHistoryMessage)
            : EmptyState(
                icon: .symbol("clock.arrow.circlepath"), title: CalcStrings.historyOffTitle,
                message: CalcStrings.historyOffMessage)
    }

    /// A saved answer: the answer as title, the question as subtitle and keyword, and when it was
    /// saved.
    nonisolated static func row(for entry: HistoryEntry) -> Row {
        Row(
            id: ItemID(AnswerRows.namespace, "history." + entry.id.uuidString), title: entry.answer,
            subtitle: entry.question, icon: .symbol("equal.circle"), accessories: [.date(entry.date)],
            keywords: [entry.question], payload: Payload(entry), memory: .never)
    }
}
