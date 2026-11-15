import Foundation
import Kit

/// The clock's values at one moment, so one load sees one "now" from start to end, and work off the
/// main thread can carry it.
nonisolated struct FrozenClock: ClockService {
    let now: Date
    let timeZone: TimeZone
    let locale: Locale
    let calendar: Calendar

    init(_ clock: any ClockService) {
        now = clock.now
        timeZone = clock.timeZone
        locale = clock.locale
        calendar = clock.calendar
    }

    /// Never used: a frozen clock does not wait.
    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
    }
}

/// Times and days as the feature writes them, in the clock's locale, calendar and time zone.
nonisolated struct TimeText: Sendable {
    private let timeStyle: Date.FormatStyle
    private let dayStyle: Date.FormatStyle
    private let shortDayStyle: Date.FormatStyle

    init(clock: any ClockService) {
        let base = Date.FormatStyle(locale: clock.locale, calendar: clock.calendar, timeZone: clock.timeZone)
        timeStyle = base.hour().minute()
        dayStyle = base.weekday(.wide).month(.wide).day()
        shortDayStyle = base.weekday(.abbreviated).month(.abbreviated).day()
    }

    /// "9:30 AM".
    func time(_ date: Date) -> String {
        date.formatted(timeStyle)
    }

    /// "9:30 AM – 10:00 AM".
    func range(_ start: Date, _ end: Date) -> String {
        Strings.timeRange(time(start), time(end))
    }

    /// "Saturday, November 14".
    func day(_ date: Date) -> String {
        date.formatted(dayStyle)
    }

    /// "Sat, Nov 14".
    func shortDay(_ date: Date) -> String {
        date.formatted(shortDayStyle)
    }
}

/// Text from the user's data made fit for one line.
nonisolated enum OneLine {
    /// Line breaks and control characters become spaces, runs of spaces collapse, and text past
    /// `limit` characters is cut with an ellipsis. Text that shows nothing, such as a run of
    /// zero-width spaces, comes back empty, so callers fall back to a title that shows.
    static func clean(_ text: String, limit: Int = 200) -> String {
        var result = ""
        var lastWasSpace = true
        var count = 0
        var showsSomething = false
        for character in text {
            let isSpace =
                character.isWhitespace
                || character.unicodeScalars.allSatisfy { $0.properties.generalCategory == .control }
            if isSpace {
                if !lastWasSpace {
                    result.append(" ")
                    lastWasSpace = true
                }
                continue
            }
            if count == limit {
                if result.hasSuffix(" ") { result.removeLast() }
                return showsSomething ? result + "\u{2026}" : ""
            }
            result.append(character)
            lastWasSpace = false
            count += 1
            if !showsSomething {
                showsSomething = !character.unicodeScalars.allSatisfy { $0.properties.generalCategory == .format }
            }
        }
        guard showsSomething else { return "" }
        if result.hasSuffix(" ") { result.removeLast() }
        return result
    }
}
