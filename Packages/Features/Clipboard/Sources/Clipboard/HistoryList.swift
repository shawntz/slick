import Foundation
import Kit

/// The Clipboard History page.
///
/// The store filters, because people search the whole text of what they copied and the history
/// may hold 50,000 items. Results come a page at a time, newest first, so the first page shows at
/// once and the rest load as the user scrolls.
final class HistoryList: ListSource {
    /// Unpinned items per page.
    static let pageSize = 100

    private let store: HistoryStore
    private let context: FeatureContext
    private let builder: HistoryActions
    let changes: ChangeSignal?
    /// Called when a load finds Paste from Other Apps missing, so the feature waits for the grant.
    var onAccessMissing: (@MainActor () -> Void)?

    init(store: HistoryStore, changes: ChangeSignal, actions: HistoryActions, context: FeatureContext) {
        self.store = store
        self.changes = changes
        self.builder = actions
        self.context = context
    }

    let filtering = ListFiltering.custom(debounce: .milliseconds(40))

    /// The notice for a paused history follows the setting.
    var reloadsOnSettings: [AnySettingKey] { [ClipboardSettings.isPaused.erased] }

    func load(_ request: ListRequest) async throws -> ListResult {
        let filter = KindFilter(optionID: request.filter)
        let query = SearchQuery(request.query)
        let cursor = request.page.flatMap { Int64($0.value) }
        let page = try await store.page(PageRequest(query: query, filter: filter, cursor: cursor, limit: Self.pageSize))
        let damagedCopy = cursor == nil ? await store.damagedCopy : nil
        try Task.checkCancellation()
        let sections = await HistoryRows.sections(
            for: page, query: query, days: DaySections(clock: context.clock, direction: .past),
            calendar: context.clock.calendar, workspace: context.workspace)
        try Task.checkCancellation()
        let isFirstPage = cursor == nil
        return ListResult(
            sections: sections,
            emptyState: isFirstPage ? emptyState(filter: filter, query: query) : nil,
            nextPage: page.nextCursor.map { ListPageToken(String($0)) },
            notice: isFirstPage ? notice(damagedCopy: damagedCopy) : nil)
    }

    func detail(for row: Row) async throws -> Detail? {
        guard let key = HistoryRows.key(of: row), let item = try await store.detail(key) else { return nil }
        let appName = item.summary.source.flatMap { context.workspace.application(bundleID: $0)?.name }
        return await HistoryDetail.make(item, appName: appName, locale: context.clock.locale)
    }

    func actions(for row: Row) -> [Action] {
        builder.actions(for: row)
    }

    private func emptyState(filter: KindFilter, query: SearchQuery) -> EmptyState {
        let icon = Icon.symbol("doc.on.clipboard")
        if !query.isEmpty {
            return EmptyState(
                icon: .symbol("magnifyingglass"), title: Strings.List.noMatchesTitle,
                message: Strings.List.noMatchesMessage)
        }
        switch filter {
        case .all:
            return EmptyState(icon: icon, title: Strings.List.emptyTitle, message: Strings.List.emptyMessage)
        case .pinned:
            return EmptyState(
                icon: .symbol("pin"), title: Strings.List.emptyPinnedTitle, message: Strings.List.emptyPinnedMessage)
        default:
            return EmptyState(icon: .symbol(filter.symbol), title: Strings.List.emptyFilterTitle(filter))
        }
    }

    /// A banner when the history file was damaged and a new one started in this session, or while
    /// new copies are not being saved, with the button that fixes it.
    private func notice(damagedCopy: URL?) -> Notice? {
        if let damagedCopy {
            return Notice(
                icon: .symbol("exclamationmark.triangle", tint: .orange), title: Strings.List.damagedTitle,
                message: Strings.List.damagedMessage,
                action: Action.reveal([damagedCopy], title: Strings.List.showDamaged).with(id: "show-damaged"))
        }
        if !context.permissions.isGranted(.pasteboard) {
            onAccessMissing?()
            let changes = changes
            return Notice(
                icon: .symbol("hand.raised"), title: Strings.List.notAllowedTitle,
                message: Strings.List.notAllowedMessage,
                action: Action(Strings.List.allow, id: "allow-access", requires: [.pasteboard]) { _ in
                    changes?.send()
                    return .keepOpen
                })
        }
        if context.settings[ClipboardSettings.isPaused] {
            return Notice(
                icon: .symbol("pause.circle"), title: Strings.List.pausedTitle, message: Strings.List.pausedMessage,
                action: Action(Strings.List.resume, id: "resume") { context in
                    context.settings[ClipboardSettings.isPaused] = false
                    return .keepOpen
                })
        }
        return nil
    }
}
