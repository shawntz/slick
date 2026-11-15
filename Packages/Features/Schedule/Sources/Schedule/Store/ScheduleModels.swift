import Foundation
import Kit

/// Which of the two EventKit stores a call reads: calendars with events, or reminder lists.
nonisolated enum CalendarKind: Hashable, Sendable {
    case events
    case reminders

    /// The permission that guards this kind.
    var permission: Permission {
        switch self {
        case .events: .calendars
        case .reminders: .reminders
        }
    }
}

/// One calendar or one reminder list.
nonisolated struct CalendarInfo: Codable, Hashable, Sendable {
    var id: String
    var title: String
    var color: KitColor?
    /// The account the calendar belongs to, such as "iCloud" or "On My Mac".
    var account: String
    /// False for subscribed and holiday calendars, which take no new events.
    var allowsModifications: Bool
    /// True for the calendar or list new items go to when none is chosen.
    var isDefault: Bool

    init(
        id: String, title: String, color: KitColor? = nil, account: String = "", allowsModifications: Bool = true,
        isDefault: Bool = false
    ) {
        self.id = id
        self.title = title
        self.color = color
        self.account = account
        self.allowsModifications = allowsModifications
        self.isDefault = isDefault
    }
}

/// How the user answered an invitation.
nonisolated enum Attendance: String, Codable, Hashable, Sendable {
    /// Not an invitation, or the user is not among the attendees.
    case none
    case pending
    case accepted
    case tentative
    case declined
}

/// One occurrence of an event, as the store hands it over. A recurring event comes as one value per
/// occurrence, all with the same ``eventID`` and each with its own start.
nonisolated struct EventOccurrence: Hashable, Sendable {
    /// The event's identifier in the store. Occurrences of a recurring event share it.
    var eventID: String
    /// The identifier the calendar server gave the event, which Calendar uses to show it.
    var externalID: String?
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var calendarID: String
    var calendarTitle: String
    var calendarColor: KitColor?
    var location: String?
    var url: URL?
    var notes: String?
    var attendance: Attendance
    var isCanceled: Bool
    var isRecurring: Bool

    init(
        eventID: String, externalID: String? = nil, title: String, start: Date, end: Date, isAllDay: Bool = false,
        calendarID: String, calendarTitle: String = "", calendarColor: KitColor? = nil, location: String? = nil,
        url: URL? = nil, notes: String? = nil, attendance: Attendance = .none, isCanceled: Bool = false,
        isRecurring: Bool = false
    ) {
        self.eventID = eventID
        self.externalID = externalID
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarID = calendarID
        self.calendarTitle = calendarTitle
        self.calendarColor = calendarColor
        self.location = location
        self.url = url
        self.notes = notes
        self.attendance = attendance
        self.isCanceled = isCanceled
        self.isRecurring = isRecurring
    }

    /// Names this occurrence: the event and its start, so each occurrence of a recurring event has
    /// its own row and the key stays the same across launches.
    var key: String { "\(eventID)@\(Int(start.timeIntervalSince1970.rounded(.down)))" }

    /// True while the event is under way at `date`.
    func isRunning(at date: Date) -> Bool {
        start <= date && date < end
    }
}

/// How urgent a reminder is, with the values EventKit stores.
nonisolated enum ReminderPriority: Int, Codable, Hashable, Sendable, CaseIterable {
    case none = 0
    case high = 1
    case medium = 5
    case low = 9

    /// EventKit's 0 to 9 scale, where 1 to 4 count as high and 6 to 9 as low.
    init(eventKitValue value: Int) {
        switch value {
        case 1...4: self = .high
        case 5: self = .medium
        case 6...9: self = .low
        default: self = .none
        }
    }
}

/// One reminder that is not completed.
nonisolated struct ReminderItem: Hashable, Sendable {
    var id: String
    var title: String
    var due: Date?
    /// False when the reminder is due on a day with no time.
    var dueHasTime: Bool
    var priority: ReminderPriority
    var listID: String
    var listTitle: String
    var listColor: KitColor?
    var notes: String?

    init(
        id: String, title: String, due: Date? = nil, dueHasTime: Bool = true, priority: ReminderPriority = .none,
        listID: String, listTitle: String = "", listColor: KitColor? = nil, notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.due = due
        self.dueHasTime = dueHasTime
        self.priority = priority
        self.listID = listID
        self.listTitle = listTitle
        self.listColor = listColor
        self.notes = notes
    }
}

/// A new event, as Create Event hands it to the store.
nonisolated struct EventDraft: Hashable, Sendable {
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    /// Nil uses the store's default calendar.
    var calendarID: String?
}

/// A new reminder, as Create Reminder hands it to the store.
nonisolated struct ReminderDraft: Hashable, Sendable {
    var title: String
    var due: Date?
    var dueHasTime: Bool
    var priority: ReminderPriority
    /// Nil uses the store's default list.
    var listID: String?
    /// The zone the due time is in, so the store can keep a timed reminder at the same moment.
    var timeZone: TimeZone
}

/// Why a store call failed.
nonisolated enum ScheduleError: Error, Hashable, Sendable, LocalizedError {
    /// The permission is missing or was taken away. The feature returns `.needsPermission`.
    case accessMissing(Permission)
    /// The event or reminder is gone, for example because another device deleted it.
    case notFound
    /// The chosen calendar or list takes no new items.
    case readOnly
    /// There is no calendar or list to save to.
    case noCalendar
    /// The calendar or list the user chose is gone, for example deleted on another device. The
    /// item is not saved anywhere else.
    case calendarGone
    /// The store refused to save.
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .accessMissing(let permission): Strings.Failure.accessMissing(permission)
        case .notFound: Strings.Failure.notFound
        case .readOnly: Strings.Failure.readOnly
        case .noCalendar: Strings.Failure.noCalendar
        case .calendarGone: Strings.Failure.calendarGone
        case .saveFailed: Strings.Failure.saveFailed
        }
    }

    var failureReason: String? {
        switch self {
        case .accessMissing: Strings.Failure.accessMissingReason
        case .notFound: Strings.Failure.notFoundReason
        case .readOnly: Strings.Failure.readOnlyReason
        case .noCalendar: Strings.Failure.noCalendarReason
        case .calendarGone: Strings.Failure.calendarGoneReason
        case .saveFailed: Strings.Failure.saveFailedReason
        }
    }
}
