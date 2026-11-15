import Foundation
import Kit
import KitTesting

@testable import Schedule

/// Synthetic calendars, lists, events and reminders around the fake clock's start: Saturday
/// 14 November 2026, 09:30 UTC. No real names.
nonisolated enum Fixture {
    static let start = Date(timeIntervalSince1970: 1_794_648_600)

    static let work = CalendarInfo(
        id: "cal-work", title: "Work", color: .rgba(red: 0.2, green: 0.4, blue: 0.9, alpha: 1), account: "Example",
        isDefault: true)
    static let home = CalendarInfo(
        id: "cal-home", title: "Home", color: .rgba(red: 0.3, green: 0.7, blue: 0.4, alpha: 1), account: "Example")
    static let holidays = CalendarInfo(
        id: "cal-holidays", title: "Holidays", account: "Subscribed", allowsModifications: false)
    static let inbox = CalendarInfo(id: "list-inbox", title: "Inbox", account: "Example", isDefault: true)
    static let errands = CalendarInfo(id: "list-errands", title: "Errands", account: "Example")
    static let archive = CalendarInfo(
        id: "list-archive", title: "Archive", account: "Shared", allowsModifications: false)

    static let calendars = [work, home, holidays]
    static let lists = [inbox, errands, archive]

    /// A UTC calendar for building dates in tests.
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    /// 2026-11-<day> at hour:minute UTC.
    static func date(day: Int, _ hour: Int, _ minute: Int = 0, timeZone: String = "UTC") -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .gmt
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)) ?? start
    }

    static func event(
        _ id: String, _ title: String, start: Date, minutes: Int = 30, calendar: CalendarInfo = work,
        allDay: Bool = false, location: String? = nil, url: URL? = nil, notes: String? = nil,
        attendance: Attendance = .accepted, canceled: Bool = false, recurring: Bool = false, end: Date? = nil
    ) -> EventOccurrence {
        EventOccurrence(
            eventID: id, externalID: "external-\(id)", title: title, start: start,
            end: end ?? start.addingTimeInterval(TimeInterval(minutes * 60)), isAllDay: allDay, calendarID: calendar.id,
            calendarTitle: calendar.title, calendarColor: calendar.color, location: location, url: url, notes: notes,
            attendance: attendance, isCanceled: canceled, isRecurring: recurring)
    }

    static func reminder(
        _ id: String, _ title: String, due: Date? = nil, hasTime: Bool = true, priority: ReminderPriority = .none,
        list: CalendarInfo = inbox, notes: String? = nil
    ) -> ReminderItem {
        ReminderItem(
            id: id, title: title, due: due, dueHasTime: hasTime, priority: priority, listID: list.id,
            listTitle: list.title, listColor: list.color, notes: notes)
    }

    static let meetLink = "https://meet.google.com/abc-defg-hij"
    static let zoomLink = "https://example.zoom.us/j/81234567890?pwd=AbCdEf123"

    /// A store over the fixture calendars and lists, with these events and reminders.
    static func store(events: [EventOccurrence] = [], reminders: [ReminderItem] = []) -> MemoryScheduleStore {
        MemoryScheduleStore(calendars: calendars, lists: lists, events: events, reminders: reminders)
    }

    /// A harness whose feature uses `store`.
    @MainActor static func harness(
        _ store: MemoryScheduleStore, fakes: FakeServices = FakeServices()
    ) -> FeatureHarness<ScheduleFeature> {
        fakes.override(ScheduleStoreKey.self, with: store)
        return FeatureHarness(ScheduleFeature.self, fakes: fakes)
    }

    /// A clock frozen at a moment in a zone.
    static func clock(_ now: Date, timeZone: String = "UTC") -> FakeClock {
        FakeClock(now: now, timeZone: TimeZone(identifier: timeZone) ?? .gmt)
    }
}

extension Row {
    var summary: EventSummary? { try? payload?.decode(EventSummary.self) }
}
