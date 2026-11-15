import CoreGraphics
import EventKit
import Foundation
import Kit

/// The live store: the user's calendars and reminders through EventKit.
///
/// Safety rules, checked line by line because no test runs this type:
///
/// - It never asks for access. It never calls `requestFullAccessToEvents`, `requestFullAccessToReminders`
///   or `requestWriteOnlyAccessToEvents`. The host asks, through Platform's permission service,
///   after the user pressed Grant.
/// - Before every call it reads `EKEventStore.authorizationStatus(for:)`, which never prompts, and
///   throws ``ScheduleError/accessMissing(_:)`` unless the status is full access.
/// - It makes its `EKEventStore` only after that check passed, on first use, never in `init`. The
///   feature makes the store in its own `init`, so nothing here runs at launch.
/// - It is an actor, so every EventKit object stays on one executor, off the main thread. Only plain
///   values leave it.
/// - It writes only what the user asked for: one new event, one new reminder, one reminder
///   completed or deleted, each saved with `commit: true` so nothing is left half done.
actor EventKitStore: ScheduleStore {
    nonisolated let changes = ChangeSignal()

    private var store: EKEventStore?
    /// The kinds that had full access when ``store`` was made or last reset. EventKit may not show a
    /// kind granted later to a store made before, so the store is reset the first time it is used for
    /// such a kind.
    private var readyKinds: Set<CalendarKind> = []
    private var observer: (any NSObjectProtocol)?

    init() {}

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Access

    func hasAccess(_ kind: CalendarKind) async -> Bool {
        Self.isAuthorized(kind)
    }

    /// The status read never prompts.
    private static func isAuthorized(_ kind: CalendarKind) -> Bool {
        EKEventStore.authorizationStatus(for: entity(kind)) == .fullAccess
    }

    private static func entity(_ kind: CalendarKind) -> EKEntityType {
        switch kind {
        case .events: .event
        case .reminders: .reminder
        }
    }

    /// The event store, once access to `kind` is confirmed. Throws when it is missing.
    private func ready(_ kind: CalendarKind) throws -> EKEventStore {
        guard Self.isAuthorized(kind) else {
            // Access was taken away. If it comes back, the store is reset before it is used again.
            readyKinds.remove(kind)
            throw ScheduleError.accessMissing(kind.permission)
        }
        if let store {
            if !readyKinds.contains(kind) {
                store.reset()
                readyKinds = Set([CalendarKind.events, .reminders].filter(Self.isAuthorized))
            }
            return store
        }
        let made = EKEventStore()
        let signal = changes
        // Posted when anything in the database changes, from this app or another. Observing it asks
        // for nothing.
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: made, queue: nil) {
            _ in
            signal.send()
        }
        store = made
        readyKinds = Set([CalendarKind.events, .reminders].filter(Self.isAuthorized))
        return made
    }

    // MARK: - Reading

    func calendars(_ kind: CalendarKind) async throws -> [CalendarInfo] {
        let store = try ready(kind)
        let defaultID =
            switch kind {
            case .events: store.defaultCalendarForNewEvents?.calendarIdentifier
            case .reminders: store.defaultCalendarForNewReminders()?.calendarIdentifier
            }
        return store.calendars(for: Self.entity(kind)).map { calendar in
            CalendarInfo(
                id: calendar.calendarIdentifier, title: calendar.title, color: Self.color(calendar.cgColor),
                account: calendar.source?.title ?? "", allowsModifications: calendar.allowsContentModifications,
                isDefault: calendar.calendarIdentifier == defaultID)
        }
    }

    func events(from start: Date, to end: Date) async throws -> [EventOccurrence] {
        let store = try ready(.events)
        guard start < end else { return [] }
        // EventKit expands recurring events into occurrences for this range.
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map(Self.occurrence)
    }

    func reminders() async throws -> [ReminderItem] {
        let store = try ready(.reminders)
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        // EventKit calls back on a queue of its own. The reminders become plain values there, so no
        // EventKit object crosses threads.
        return await withCheckedContinuation { continuation in
            _ = store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(Self.reminder))
            }
        }
    }

    // MARK: - Writing

    func createEvent(_ draft: EventDraft) async throws -> EventOccurrence {
        let store = try ready(.events)
        let calendar = try Self.target(draft.calendarID, for: .event, in: store) { store.defaultCalendarForNewEvents }
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.isAllDay = draft.isAllDay
        event.startDate = draft.start
        event.endDate = draft.end
        event.calendar = calendar
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw ScheduleError.saveFailed
        }
        changes.send()
        return Self.occurrence(event)
    }

    func createReminder(_ draft: ReminderDraft) async throws -> ReminderItem {
        let store = try ready(.reminders)
        let list = try Self.target(draft.listID, for: .reminder, in: store) { store.defaultCalendarForNewReminders() }
        let reminder = EKReminder(eventStore: store)
        reminder.title = draft.title
        reminder.calendar = list
        reminder.priority = draft.priority.rawValue
        if let due = draft.due {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = draft.timeZone
            var components = calendar.dateComponents(
                draft.dueHasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: due)
            components.calendar = calendar
            // A timed reminder keeps its zone. A day with no time stays on that day wherever the user is.
            components.timeZone = draft.dueHasTime ? draft.timeZone : nil
            reminder.dueDateComponents = components
            // Reminders shows a notification for a timed reminder because of this alarm.
            if draft.dueHasTime { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw ScheduleError.saveFailed
        }
        changes.send()
        return Self.reminder(reminder)
    }

    func complete(reminderID: String) async throws {
        let store = try ready(.reminders)
        guard let reminder = store.calendarItem(withIdentifier: reminderID) as? EKReminder else {
            throw ScheduleError.notFound
        }
        reminder.isCompleted = true
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw ScheduleError.saveFailed
        }
        changes.send()
    }

    func delete(reminderID: String) async throws {
        let store = try ready(.reminders)
        guard let reminder = store.calendarItem(withIdentifier: reminderID) as? EKReminder else {
            throw ScheduleError.notFound
        }
        do {
            try store.remove(reminder, commit: true)
        } catch {
            throw ScheduleError.saveFailed
        }
        changes.send()
    }

    /// The calendar or list a new item goes to. With an ID, only that one, and only when it holds
    /// this kind of item: a calendar deleted since the form opened is an error, never a reason to
    /// save somewhere the user did not pick. Without one, the store's default.
    private static func target(
        _ id: String?, for entity: EKEntityMask, in store: EKEventStore, default fallback: () -> EKCalendar?
    ) throws -> EKCalendar {
        let calendar: EKCalendar
        if let id {
            guard let chosen = store.calendar(withIdentifier: id), chosen.allowedEntityTypes.contains(entity) else {
                throw ScheduleError.calendarGone
            }
            calendar = chosen
        } else {
            guard let fallback = fallback() else { throw ScheduleError.noCalendar }
            calendar = fallback
        }
        guard calendar.allowsContentModifications else { throw ScheduleError.readOnly }
        return calendar
    }

    // MARK: - Conversion

    private static func occurrence(_ event: EKEvent) -> EventOccurrence {
        let start: Date = event.startDate
        let end: Date = event.endDate ?? start
        let calendar: EKCalendar? = event.calendar
        return EventOccurrence(
            eventID: event.eventIdentifier ?? event.calendarItemIdentifier,
            externalID: event.calendarItemExternalIdentifier, title: event.title ?? "", start: start,
            end: max(start, end), isAllDay: event.isAllDay, calendarID: calendar?.calendarIdentifier ?? "",
            calendarTitle: calendar?.title ?? "", calendarColor: color(calendar?.cgColor), location: event.location,
            url: event.url, notes: event.notes, attendance: attendance(of: event),
            isCanceled: event.status == .canceled, isRecurring: event.hasRecurrenceRules)
    }

    private static func attendance(of event: EKEvent) -> Attendance {
        guard let me = event.attendees?.first(where: \.isCurrentUser) else { return .none }
        switch me.participantStatus {
        case .accepted, .delegated, .completed: return .accepted
        case .declined: return .declined
        case .tentative: return .tentative
        case .pending, .inProcess: return .pending
        case .unknown: return .none
        @unknown default: return .none
        }
    }

    private static func reminder(_ reminder: EKReminder) -> ReminderItem {
        let components = reminder.dueDateComponents
        var due: Date?
        if let components {
            var calendar = components.calendar ?? Calendar(identifier: .gregorian)
            calendar.timeZone = components.timeZone ?? .current
            due = calendar.date(from: components)
        }
        let list: EKCalendar? = reminder.calendar
        return ReminderItem(
            id: reminder.calendarItemIdentifier, title: reminder.title ?? "", due: due,
            dueHasTime: components?.hour != nil, priority: ReminderPriority(eventKitValue: reminder.priority),
            listID: list?.calendarIdentifier ?? "", listTitle: list?.title ?? "", listColor: color(list?.cgColor),
            notes: reminder.notes)
    }

    /// A calendar's color in sRGB.
    private static func color(_ cgColor: CGColor?) -> KitColor? {
        guard let cgColor, let space = CGColorSpace(name: CGColorSpace.sRGB),
            let converted = cgColor.converted(to: space, intent: .defaultIntent, options: nil),
            let parts = converted.components, parts.count >= 3
        else { return nil }
        return .rgba(
            red: Double(parts[0]), green: Double(parts[1]), blue: Double(parts[2]),
            alpha: parts.count > 3 ? Double(parts[3]) : 1)
    }
}
