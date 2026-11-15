import Foundation
import Kit
import Synchronization

/// Calendars and reminders kept in memory, for tests, scenarios, self-tests and benchmarks. It
/// touches nothing on the Mac. Tests fill it, take access away, make writes fail, and read back what
/// the feature asked for.
///
/// Like EventKit, it hands over each occurrence of a recurring event as its own value: a test adds
/// the occurrences it wants, sharing one event ID.
nonisolated final class MemoryScheduleStore: ScheduleStore {
    private struct State {
        var calendars: [CalendarInfo]
        var lists: [CalendarInfo]
        var events: [EventOccurrence]
        var reminders: [ReminderItem]
        var denied: Set<CalendarKind> = []
        var failsWrites = false
        var createdEvents: [EventDraft] = []
        var createdReminders: [ReminderDraft] = []
        var completed: [String] = []
        var deleted: [String] = []
        var eventQueries: [ClosedRange<Date>] = []
        var nextID = 1
    }

    let changes = ChangeSignal()
    private let state: Mutex<State>

    init(
        calendars: [CalendarInfo] = [], lists: [CalendarInfo] = [], events: [EventOccurrence] = [],
        reminders: [ReminderItem] = []
    ) {
        state = Mutex(State(calendars: calendars, lists: lists, events: events, reminders: reminders))
    }

    // MARK: - For tests

    /// Takes access away, or gives it back, as if the user changed it in System Settings.
    func setAccess(_ kind: CalendarKind, granted: Bool) {
        state.withLock { state in
            if granted { state.denied.remove(kind) } else { state.denied.insert(kind) }
        }
    }

    /// Makes every write fail from now on, as a store that refuses to save.
    func setFailsWrites(_ fails: Bool) {
        state.withLock { $0.failsWrites = fails }
    }

    /// Adds an event occurrence, as another app would.
    func add(_ event: EventOccurrence) {
        state.withLock { $0.events.append(event) }
        changes.send()
    }

    /// Adds a reminder, as another app would.
    func add(_ reminder: ReminderItem) {
        state.withLock { $0.reminders.append(reminder) }
        changes.send()
    }

    /// Removes a calendar or a reminder list, as another device would.
    func removeCalendar(id: String) {
        state.withLock { state in
            state.calendars.removeAll { $0.id == id }
            state.lists.removeAll { $0.id == id }
        }
        changes.send()
    }

    var createdEvents: [EventDraft] { state.withLock { $0.createdEvents } }
    var createdReminders: [ReminderDraft] { state.withLock { $0.createdReminders } }
    var completedReminderIDs: [String] { state.withLock { $0.completed } }
    var deletedReminderIDs: [String] { state.withLock { $0.deleted } }
    var allReminders: [ReminderItem] { state.withLock { $0.reminders } }
    var allEvents: [EventOccurrence] { state.withLock { $0.events } }
    /// Every range ``events(from:to:)`` was asked for, in order.
    var eventQueries: [ClosedRange<Date>] { state.withLock { $0.eventQueries } }

    // MARK: - ScheduleStore

    func hasAccess(_ kind: CalendarKind) async -> Bool {
        state.withLock { !$0.denied.contains(kind) }
    }

    func calendars(_ kind: CalendarKind) async throws -> [CalendarInfo] {
        try state.withLock { state in
            try Self.check(kind, in: state)
            return kind == .events ? state.calendars : state.lists
        }
    }

    func events(from start: Date, to end: Date) async throws -> [EventOccurrence] {
        try state.withLock { state in
            try Self.check(.events, in: state)
            state.eventQueries.append(start...max(start, end))
            // Overlap, as EventKit's predicate does. An event with no length counts when it starts in range.
            return state.events.filter { event in
                event.start < end && (event.end > start || (event.end == event.start && event.start >= start))
            }
        }
    }

    func createEvent(_ draft: EventDraft) async throws -> EventOccurrence {
        let event = try state.withLock { state -> EventOccurrence in
            try Self.check(.events, in: state)
            if state.failsWrites { throw ScheduleError.saveFailed }
            let calendar = try Self.target(draft.calendarID, in: state.calendars)
            let id = "memory-event-\(state.nextID)"
            state.nextID += 1
            let event = EventOccurrence(
                eventID: id, title: draft.title, start: draft.start, end: draft.end, isAllDay: draft.isAllDay,
                calendarID: calendar.id, calendarTitle: calendar.title, calendarColor: calendar.color)
            state.events.append(event)
            state.createdEvents.append(draft)
            return event
        }
        changes.send()
        return event
    }

    func reminders() async throws -> [ReminderItem] {
        try state.withLock { state in
            try Self.check(.reminders, in: state)
            return state.reminders
        }
    }

    func createReminder(_ draft: ReminderDraft) async throws -> ReminderItem {
        let reminder = try state.withLock { state -> ReminderItem in
            try Self.check(.reminders, in: state)
            if state.failsWrites { throw ScheduleError.saveFailed }
            let list = try Self.target(draft.listID, in: state.lists)
            let id = "memory-reminder-\(state.nextID)"
            state.nextID += 1
            let reminder = ReminderItem(
                id: id, title: draft.title, due: draft.due, dueHasTime: draft.dueHasTime, priority: draft.priority,
                listID: list.id, listTitle: list.title, listColor: list.color)
            state.reminders.append(reminder)
            state.createdReminders.append(draft)
            return reminder
        }
        changes.send()
        return reminder
    }

    func complete(reminderID: String) async throws {
        try state.withLock { state in
            try Self.check(.reminders, in: state)
            if state.failsWrites { throw ScheduleError.saveFailed }
            guard let index = state.reminders.firstIndex(where: { $0.id == reminderID }) else {
                throw ScheduleError.notFound
            }
            state.reminders.remove(at: index)
            state.completed.append(reminderID)
        }
        changes.send()
    }

    func delete(reminderID: String) async throws {
        try state.withLock { state in
            try Self.check(.reminders, in: state)
            if state.failsWrites { throw ScheduleError.saveFailed }
            guard let index = state.reminders.firstIndex(where: { $0.id == reminderID }) else {
                throw ScheduleError.notFound
            }
            state.reminders.remove(at: index)
            state.deleted.append(reminderID)
        }
        changes.send()
    }

    private static func check(_ kind: CalendarKind, in state: State) throws {
        if state.denied.contains(kind) { throw ScheduleError.accessMissing(kind.permission) }
    }

    /// The calendar a new item goes to: the chosen one, else the default, else the first writable.
    /// A chosen calendar that is gone is an error, as in ``EventKitStore``: the item is never saved
    /// to a calendar the user did not pick.
    private static func target(_ id: String?, in calendars: [CalendarInfo]) throws -> CalendarInfo {
        if let id {
            guard let chosen = calendars.first(where: { $0.id == id }) else { throw ScheduleError.calendarGone }
            guard chosen.allowsModifications else { throw ScheduleError.readOnly }
            return chosen
        }
        let chosen = calendars.first { $0.isDefault } ?? calendars.first { $0.allowsModifications }
        guard let chosen else { throw ScheduleError.noCalendar }
        guard chosen.allowsModifications else { throw ScheduleError.readOnly }
        return chosen
    }
}

// MARK: - Sample data

extension MemoryScheduleStore {
    /// A small synthetic schedule around `now`, for scenarios and self-tests: a meeting with a link
    /// about to start, the rest of the day, a recurring stand-up, an all-day event and a few
    /// reminders. No real names.
    static func sample(now: Date, calendar: Calendar) -> MemoryScheduleStore {
        let work = CalendarInfo(
            id: "sample-work", title: "Work", color: .rgba(red: 0.2, green: 0.47, blue: 0.96, alpha: 1),
            account: "On My Mac", isDefault: true)
        let home = CalendarInfo(
            id: "sample-home", title: "Home", color: .rgba(red: 0.3, green: 0.75, blue: 0.4, alpha: 1),
            account: "On My Mac")
        let holidays = CalendarInfo(
            id: "sample-holidays", title: "Holidays", color: .rgba(red: 0.9, green: 0.3, blue: 0.3, alpha: 1),
            account: "Subscribed", allowsModifications: false)
        let inbox = CalendarInfo(
            id: "sample-inbox", title: "Inbox", color: .rgba(red: 0.2, green: 0.6, blue: 0.95, alpha: 1),
            account: "On My Mac", isDefault: true)
        let errands = CalendarInfo(
            id: "sample-errands", title: "Errands", color: .rgba(red: 0.95, green: 0.6, blue: 0.2, alpha: 1),
            account: "On My Mac")

        let today = calendar.startOfDay(for: now)
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let base = calendar.date(byAdding: .day, value: day, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
        }
        func event(
            _ id: String, _ title: String, _ start: Date, minutes: Int, in calendar: CalendarInfo,
            location: String? = nil, notes: String? = nil, url: URL? = nil, recurring: Bool = false
        ) -> EventOccurrence {
            EventOccurrence(
                eventID: id, title: title, start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)),
                calendarID: calendar.id, calendarTitle: calendar.title, calendarColor: calendar.color,
                location: location, url: url, notes: notes, attendance: .accepted, isRecurring: recurring)
        }

        let soon = now.addingTimeInterval(5 * 60)
        var events = [
            event(
                "sample-review", "Design Review", soon, minutes: 30, in: work,
                notes: "Join with Google Meet: https://meet.google.com/abc-defg-hij"),
            event("sample-lunch", "Team Lunch", at(0, 12, 30), minutes: 60, in: work, location: "Cafe on the corner"),
            event("sample-run", "Evening Run", at(0, 18), minutes: 45, in: home),
            event(
                "sample-planning", "Planning", at(1, 10), minutes: 60, in: work,
                url: URL(string: "https://example.zoom.us/j/1234567890")),
        ]
        for day in 1...5 {
            events.append(
                event(
                    "sample-standup", "Stand-up", at(day, 9, 15), minutes: 15, in: work,
                    notes: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_sample%40thread.v2/0",
                    recurring: true
                ))
        }
        events.append(
            EventOccurrence(
                eventID: "sample-holiday", title: "Founders Day", start: at(2, 0), end: at(3, 0), isAllDay: true,
                calendarID: holidays.id, calendarTitle: holidays.title, calendarColor: holidays.color))

        let reminders = [
            ReminderItem(
                id: "sample-plants", title: "Water the plants",
                due: calendar.date(byAdding: .day, value: -1, to: today),
                dueHasTime: false, listID: inbox.id, listTitle: inbox.title, listColor: inbox.color),
            ReminderItem(
                id: "sample-invoice", title: "Send the invoice", due: at(0, 15), priority: .high, listID: inbox.id,
                listTitle: inbox.title, listColor: inbox.color),
            ReminderItem(
                id: "sample-library", title: "Renew the library card", due: at(4, 0), dueHasTime: false,
                listID: errands.id, listTitle: errands.title, listColor: errands.color),
            ReminderItem(
                id: "sample-dentist", title: "Book a dentist appointment", listID: errands.id,
                listTitle: errands.title, listColor: errands.color),
        ]
        return MemoryScheduleStore(
            calendars: [work, home, holidays], lists: [inbox, errands], events: events, reminders: reminders)
    }
}
