import Foundation
import Kit

/// My Schedule: the user's events by day, from now on.
///
/// The host filters as the user types, over titles, calendars, places and meeting services. The
/// list loads again when the store changes or a setting it depends on changes.
final class ScheduleList: ListSource {
    private let store: any ScheduleStore
    private let context: FeatureContext

    init(store: any ScheduleStore, context: FeatureContext) {
        self.store = store
        self.context = context
    }

    var changes: ChangeSignal? { store.changes }
    let reloadsOnSettings = ScheduleSettings.scheduleKeys

    func load(_ request: ListRequest) async throws -> ListResult {
        let clock = FrozenClock(context.clock)
        let options = ScheduleOptions(context.settings)
        let range = EventRows.range(clock: clock, days: options.days)
        let events: [EventOccurrence]
        do {
            events = try await store.events(from: range.start, to: range.end)
        } catch ScheduleError.accessMissing(let permission) {
            return ListResult(sections: [], emptyState: AccessEmptyState.make(for: permission))
        }
        try Task.checkCancellation()
        let page = await EventRows.page(events, options: options, clock: clock)
        try Task.checkCancellation()
        // While the list shows, it loads again when an event starts or ends or the day turns, so a
        // Now tag, an ended meeting or the Today section is never left stale.
        return ListResult(sections: page.sections, refreshAfter: page.refreshAfter)
    }

    func actions(for row: Row) -> [Action] {
        guard let summary = try? row.payload?.decode(EventSummary.self) else { return [] }
        return EventActions.actions(for: summary, now: context.clock.now, text: TimeText(clock: context.clock))
    }

    /// The empty state when no event is coming up in the range.
    static func emptyState(days: Int) -> EmptyState {
        EmptyState(
            icon: .symbol("calendar"), title: Strings.Schedule.emptyTitle, message: Strings.Schedule.emptyMessage(days),
            actions: [
                .runCommand(
                    ItemID.command(
                        feature: ScheduleFeature.manifest.id, command: ScheduleFeature.CommandID.createEvent),
                    title: Strings.Commands.createEvent, icon: .symbol("calendar.badge.plus"))
            ])
    }
}

/// What a list shows when the store says access is missing: the reason and a button that runs the
/// host's grant flow, then loads again.
enum AccessEmptyState {
    static func make(for permission: Permission) -> EmptyState {
        EmptyState(
            icon: .symbol("lock"), title: Strings.Access.title(permission), message: Strings.Access.message(permission),
            actions: [
                Action(
                    Strings.Access.grant(permission), id: "grant-access", icon: .symbol("lock.open"),
                    requires: [permission]
                ) {
                    context in
                    context.reload()
                    return .keepOpen
                }
            ])
    }
}
