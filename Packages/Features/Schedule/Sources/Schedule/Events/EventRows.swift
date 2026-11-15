import Foundation
import Kit

/// What an event row carries for its actions, so they work from the row alone, also after a
/// relaunch. Text is cut so the payload stays under 1 KB.
nonisolated struct EventSummary: Codable, Hashable, Sendable {
    var eventID: String
    var externalID: String?
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    var link: MeetingLink?
    var calendarTitle: String

    init(_ event: EventOccurrence, link: MeetingLink?) {
        eventID = event.eventID
        externalID = event.externalID
        title = OneLine.clean(event.title, limit: 160)
        start = event.start
        end = event.end
        isAllDay = event.isAllDay
        location = event.location.map { OneLine.clean($0, limit: 160) }.flatMap { $0.isEmpty ? nil : $0 }
        self.link = link
        calendarTitle = OneLine.clean(event.calendarTitle, limit: 60)
    }
}

/// One event on one day of My Schedule. An event that runs over several days appears on each.
nonisolated struct EventEntry: Sendable {
    var day: Date
    var event: EventOccurrence
    var link: MeetingLink?
    /// Which of the event's days this is, from 0.
    var index: Int
    var dayCount: Int
}

/// Turns events into My Schedule's sections and rows. Pure and `nonisolated`, so it runs off the
/// main thread and its tests need no harness.
nonisolated enum EventRows {
    /// The namespace of My Schedule's rows.
    static let namespace = "schedule.event"

    /// What My Schedule asks the store for: from now to the end of the last day it shows.
    static func range(clock: any ClockService, days: Int) -> (start: Date, end: Date) {
        let calendar = clock.calendar
        let today = calendar.startOfDay(for: clock.now)
        let end = calendar.date(byAdding: .day, value: max(1, days), to: today) ?? today.addingTimeInterval(86_400)
        return (clock.now, end)
    }

    /// Builds the sections off the main thread.
    @concurrent static func sections(_ events: [EventOccurrence], options: ScheduleOptions, clock: FrozenClock) async
        -> [ListSection]
    {
        build(events, options: options, clock: clock)
    }

    /// Builds the sections off the main thread, with how long they stay right.
    @concurrent static func page(_ events: [EventOccurrence], options: ScheduleOptions, clock: FrozenClock) async
        -> (sections: [ListSection], refreshAfter: Duration?)
    {
        (build(events, options: options, clock: clock), refreshDelay(events, options: options, clock: clock))
    }

    /// How long until the list changes with no change in the store: an event starts and is tagged
    /// Now, an event ends and leaves, or the day turns and the sections take new titles. At least a
    /// second, so a busy minute never makes the host reload in a loop.
    static func refreshDelay(_ events: [EventOccurrence], options: ScheduleOptions, clock: any ClockService)
        -> Duration?
    {
        let now = clock.now
        let calendar = clock.calendar
        var next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        for event in events where options.shows(event) {
            for moment in [event.start, event.end] where moment > now && next.map({ moment < $0 }) ?? true {
                next = moment
            }
        }
        guard let next else { return nil }
        return .seconds(max(1, next.timeIntervalSince(now).rounded(.up)))
    }

    /// One section per day from today, titled Today, Tomorrow, then by weekday and date. All-day
    /// events come first in a day, then the rest by start time. Events that have ended are left out.
    static func build(_ events: [EventOccurrence], options: ScheduleOptions, clock: any ClockService) -> [ListSection] {
        let entries = self.entries(events, options: options, clock: clock)
        let text = TimeText(clock: clock)
        let now = clock.now
        return DaySections(clock: clock, direction: .future).sections(entries, date: \.day) {
            row(for: $0, now: now, text: text)
        }
    }

    /// The events My Schedule shows, one entry per day each covers, in display order.
    static func entries(_ events: [EventOccurrence], options: ScheduleOptions, clock: any ClockService) -> [EventEntry]
    {
        let calendar = clock.calendar
        let now = clock.now
        let today = calendar.startOfDay(for: now)
        let rangeEnd = range(clock: clock, days: options.days).end
        var entries: [EventEntry] = []
        for event in events where options.shows(event) && event.start < rangeEnd {
            // Running or still to come. An event with no length counts until its start passes.
            guard event.end > now || (event.end <= event.start && event.start >= now) else { continue }
            let link = MeetingLinkFinder.find(url: event.url, location: event.location, notes: event.notes)
            let first = calendar.startOfDay(for: event.start)
            // An event that ends at midnight does not cover the day that starts then.
            let last = calendar.startOfDay(
                for: event.end > event.start ? event.end.addingTimeInterval(-1) : event.start)
            let count = (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
            var day = max(first, today)
            while day <= last, day < rangeEnd {
                let index = calendar.dateComponents([.day], from: first, to: day).day ?? 0
                entries.append(EventEntry(day: day, event: event, link: link, index: index, dayCount: count))
                guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
                day = next
            }
        }
        entries.sort { left, right in
            if left.day != right.day { return left.day < right.day }
            if left.event.isAllDay != right.event.isAllDay { return left.event.isAllDay }
            if left.event.start != right.event.start { return left.event.start < right.event.start }
            if left.event.title != right.event.title { return left.event.title < right.event.title }
            return left.event.key < right.event.key
        }
        return entries
    }

    /// The row for one event on one day.
    static func row(for entry: EventEntry, now: Date, text: TimeText) -> Row {
        let event = entry.event
        var accessories: [Accessory] = []
        if event.isCanceled {
            accessories.append(.tag(Strings.Schedule.canceled, color: .red))
        } else if event.attendance == .declined {
            accessories.append(.tag(Strings.Schedule.declined, color: .gray))
        } else if !event.isAllDay && event.isRunning(at: now) {
            accessories.append(.tag(Strings.Schedule.now, color: .green))
        } else if event.attendance == .pending {
            accessories.append(.tag(Strings.Schedule.invited, color: .orange))
        }
        if let link = entry.link {
            accessories.append(.icon(.symbol("video.fill"), tooltip: link.provider.name))
        }
        if let place = place(of: event) { accessories.append(.text(place)) }
        var keywords = [OneLine.clean(event.calendarTitle, limit: 60)]
        if let location = event.location { keywords.append(OneLine.clean(location, limit: 80)) }
        if let link = entry.link { keywords.append(link.provider.name) }
        return Row(
            id: ItemID(namespace, event.key), title: title(of: event), subtitle: subtitle(for: entry, text: text),
            icon: .symbol("circle.fill", tint: event.calendarColor ?? .gray), accessories: accessories,
            keywords: keywords.filter { !$0.isEmpty }, payload: Payload(EventSummary(event, link: entry.link)))
    }

    static func title(of event: EventOccurrence) -> String {
        let title = OneLine.clean(event.title)
        return title.isEmpty ? Strings.Schedule.untitled : title
    }

    /// When the event happens on this day.
    static func subtitle(for entry: EventEntry, text: TimeText) -> String {
        let event = entry.event
        if event.isAllDay {
            return entry.dayCount > 1
                ? Strings.Schedule.allDayOf(day: entry.index + 1, of: entry.dayCount) : Strings.Schedule.allDay
        }
        guard entry.dayCount > 1 else { return text.range(event.start, event.end) }
        if entry.index == 0 { return Strings.Schedule.starts(text.time(event.start)) }
        if entry.index == entry.dayCount - 1 { return Strings.Schedule.ends(text.time(event.end)) }
        return Strings.Schedule.continues
    }

    /// The location to show beside the row, unless it is only a link, which the video icon stands
    /// for.
    static func place(of event: EventOccurrence) -> String? {
        guard let location = event.location else { return nil }
        let place = OneLine.clean(location, limit: 40)
        if place.isEmpty || place.contains("://") || MeetingLinkFinder.find(in: place) != nil { return nil }
        return place
    }
}

/// Links that open an event in Calendar and a reminder in Reminders, and the apps to fall back on.
nonisolated enum CalendarAppLinks {
    static let calendarBundleID = "com.apple.iCal"
    static let remindersBundleID = "com.apple.reminders"

    private static let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#;"))

    /// Calendar's own link to show an event: `ical://ekevent/<id>?method=show&options=more`, with
    /// the server's identifier when the event has one.
    static func event(externalID: String?, eventID: String) -> URL? {
        let id = externalID.flatMap { $0.isEmpty ? nil : $0 } ?? eventID
        guard !id.isEmpty, let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "ical://ekevent/\(encoded)?method=show&options=more")
    }

    /// Reminders' own link to show a reminder.
    static func reminder(id: String) -> URL? {
        guard !id.isEmpty, let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "x-apple-reminderkit://REMCDReminder/\(encoded)")
    }
}
