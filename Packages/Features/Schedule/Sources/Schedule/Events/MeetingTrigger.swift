import Foundation
import Kit

/// Offers to join a meeting with a link in root search's empty state, from shortly before it
/// starts until five minutes after.
///
/// The lead time is a setting, ten minutes by default. Urgency rises from zero when the window
/// opens to full five minutes before the start, or at the opening for a shorter lead, and stays
/// full until five minutes after the start. From that full point the meeting is imminent and may
/// take a second slot. One occurrence of a meeting is never worth remembering, so its row has
/// `memory: .never` and expires with the window.
final class MeetingTrigger: SuggestionTrigger {
    /// The suggestion stays this long after the start.
    nonisolated static let lateness: TimeInterval = 5 * 60
    /// Urgency is full from this long before the start at the latest.
    nonisolated static let fullFrom: TimeInterval = 5 * 60
    /// The namespace of suggestion rows, apart from My Schedule's.
    nonisolated static let rowNamespace = "schedule.meeting"

    let id = "meeting-soon"
    let namespace = MeetingTrigger.rowNamespace
    /// People who keep the suggestion on usually join their meetings.
    let prior = AcceptancePrior(accepts: 4, rejects: 1)
    let refreshInterval: Duration? = .seconds(60)
    let requires: [Permission] = [.calendars]
    let reloadsOnSettings = ScheduleSettings.suggestionKeys

    private let store: any ScheduleStore
    private let settings: FeatureSettings

    init(store: any ScheduleStore, settings: FeatureSettings) {
        self.store = store
        self.settings = settings
    }

    var changes: ChangeSignal? { store.changes }

    func suggestions(at date: Date) async throws -> [Suggestion] {
        guard settings[ScheduleSettings.suggestsMeetings] else { return [] }
        let lead = settings[ScheduleSettings.leadTime].seconds
        let options = ScheduleOptions(settings)
        // Every meeting whose window holds `date` starts in (date - lateness, date + lead].
        let events = try await store.events(
            from: date.addingTimeInterval(-Self.lateness), to: date.addingTimeInterval(lead + 1))
        try Task.checkCancellation()
        return await Self.suggestions(events, at: date, lead: lead, options: options)
    }

    /// Finds the links off the main thread: notes can be long.
    @concurrent static func suggestions(
        _ events: [EventOccurrence], at date: Date, lead: TimeInterval, options: ScheduleOptions
    ) async -> [Suggestion] {
        build(events, at: date, lead: lead, options: options)
    }

    nonisolated static func build(
        _ events: [EventOccurrence], at date: Date, lead: TimeInterval, options: ScheduleOptions
    )
        -> [Suggestion]
    {
        events.compactMap { event in
            guard !event.isAllDay, !event.isCanceled, event.attendance != .declined,
                !options.hiddenCalendars.contains(event.calendarID)
            else { return nil }
            let opens = event.start.addingTimeInterval(-lead)
            let expires = event.start.addingTimeInterval(lateness)
            guard opens <= date, date < expires,
                let link = MeetingLinkFinder.find(url: event.url, location: event.location, notes: event.notes)
            else { return nil }
            let full = max(opens, event.start.addingTimeInterval(-fullFrom))
            let summary = EventSummary(event, link: link)
            let row = Row(
                id: ItemID(rowNamespace, event.key), title: Strings.Suggestion.title(EventRows.title(of: event)),
                subtitle: Strings.Suggestion.subtitle(provider: link.provider.name),
                icon: .symbol("video.fill", tint: event.calendarColor), accessories: [.date(event.start)],
                payload: Payload(summary), memory: .never, expires: expires)
            return Suggestion(
                id: event.key, row: row, urgency: .ramp(start: opens, full: full, end: expires), expires: expires,
                imminentFrom: full)
        }
        .sorted { $0.row.expires ?? .distantFuture < $1.row.expires ?? .distantFuture }
    }

    func actions(for row: Row) -> [Action] {
        guard let summary = try? row.payload?.decode(EventSummary.self) else { return [] }
        return EventActions.suggestionActions(for: summary)
    }
}
