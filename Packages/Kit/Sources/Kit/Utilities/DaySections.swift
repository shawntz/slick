import Foundation

/// Groups dated rows into sections titled by day: Today, Yesterday or Tomorrow, a weekday within the
/// week, then a date, such as "Monday, November 9".
///
/// It reads today from the clock you pass and formats with the clock's calendar, locale and time
/// zone, never the system's, so tests can fix the date. Make one per load: it fixes today when made.
public struct DaySections: Sendable {
    /// Which way the list looks from today.
    public enum Direction: Sendable {
        /// History: Today, Yesterday, then the previous days of the week.
        case past
        /// A schedule: Today, Tomorrow, then the coming days of the week.
        case future
    }

    private let calendar: Calendar
    private let today: Date
    private let direction: Direction
    private let weekday: Date.FormatStyle
    private let date: Date.FormatStyle

    public init(clock: any ClockService, direction: Direction) {
        calendar = clock.calendar
        today = clock.calendar.startOfDay(for: clock.now)
        self.direction = direction
        let base = Date.FormatStyle(locale: clock.locale, calendar: clock.calendar, timeZone: clock.timeZone)
        weekday = base.weekday(.wide)
        date = base.weekday(.wide).month(.wide).day()
    }

    /// The title of the section a date belongs to.
    public func title(for day: Date) -> String {
        let start = calendar.startOfDay(for: day)
        let offset = calendar.dateComponents([.day], from: today, to: start).day ?? 0
        let distance = direction == .past ? -offset : offset
        switch distance {
        case ...0: return "Today"
        case 1: return direction == .past ? "Yesterday" : "Tomorrow"
        case 2..<7: return day.formatted(weekday)
        default: return day.formatted(date)
        }
    }

    /// One section per day, in the items' order, which must already be sorted by date. Section IDs
    /// are the day's date in `yyyy-MM-dd` form, so they stay stable as titles move from "Today" to
    /// "Yesterday".
    public func sections<Item>(_ items: [Item], date: (Item) -> Date, row: (Item) -> Row) -> [ListSection] {
        var sections: [ListSection] = []
        for item in items {
            let day = date(item)
            let title = title(for: day)
            if sections.last?.title == title {
                sections[sections.count - 1].rows.append(row(item))
            } else {
                sections.append(ListSection(title, id: sectionID(for: day), rows: [row(item)]))
            }
        }
        return sections
    }

    private func sectionID(for day: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let month = parts.month ?? 0
        let dayOfMonth = parts.day ?? 0
        return "\(parts.year ?? 0)-\(month < 10 ? "0" : "")\(month)-\(dayOfMonth < 10 ? "0" : "")\(dayOfMonth)"
    }
}
