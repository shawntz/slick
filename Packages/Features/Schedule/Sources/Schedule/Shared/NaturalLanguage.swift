import Foundation
import Kit

/// What a typed phrase such as "Lunch tomorrow at 1pm" says: a title and, when it names one, a
/// moment and a length.
nonisolated struct ParsedPhrase: Hashable, Sendable {
    var title: String
    var date: Date?
    /// The length the phrase gives, as in "from 2pm to 3:30pm".
    var duration: TimeInterval?
    /// True when the phrase names a day but no time, as in "Holiday on Friday".
    var isDateOnly: Bool

    static let empty = ParsedPhrase(title: "", date: nil, duration: nil, isDateOnly: false)
}

/// Reads dates in typed phrases with `NSDataDetector`.
///
/// The detector resolves "tomorrow" against the system clock and cannot be given another. So the
/// parser takes what the detector found apart into a number of days from the detector's today and a
/// time of day, and puts them back together on the feature's clock. In the app the feature's clock
/// is the system clock, and this changes nothing. In tests it makes "tomorrow at 1pm" mean the fake
/// clock's tomorrow. A weekday or a date on the calendar is still read as days from the system's
/// today, so tests use relative phrases for exact days.
nonisolated enum NaturalLanguage {
    /// Longest phrase read. A form argument is a short line.
    static let limit = 500

    /// Parses off the main thread: making a detector and matching costs a few milliseconds.
    @concurrent static func parse(_ text: String, clock: FrozenClock) async -> ParsedPhrase {
        parse(text, clock: clock, detectorClock: FrozenClock(SystemClock()))
    }

    /// Parses `text`, mapping the detector's answer from `detectorClock` to `clock`.
    static func parse(_ text: String, clock: any ClockService, detectorClock: any ClockService) -> ParsedPhrase {
        let text = OneLine.clean(String(text.prefix(limit)), limit: limit)
        guard !text.isEmpty else { return .empty }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
            let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let found = match.date, let range = Range(match.range, in: text)
        else {
            return ParsedPhrase(title: text, date: nil, duration: nil, isDateOnly: false)
        }
        // The detector takes "Lunch" or "Dinner" as a time of day and puts it in the match. Such
        // leading words stay in the title.
        let start = dateStart(in: text[range])
        let phrase = text[start..<range.upperBound]
        let isDateOnly = !mentionsTime(phrase)
        let date = map(found, from: detectorClock, to: clock, dateOnly: isDateOnly)
        let title = cleanTitle(String(text[..<start]), String(text[range.upperBound...]))
        let duration = match.duration > 0 ? match.duration : nil
        return ParsedPhrase(title: title, date: date, duration: duration, isDateOnly: isDateOnly)
    }

    /// Words a date or time can start with, besides numbers.
    private static let dateWords: Set<String> = [
        "today", "tomorrow", "tonight", "yesterday", "at", "on", "in", "next", "this", "from", "by", "noon", "midnight",
        "morning", "afternoon", "evening", "the", "every", "monday", "tuesday", "wednesday", "thursday", "friday",
        "saturday", "sunday", "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun", "january",
        "february", "march", "april", "may", "june", "july", "august", "september", "october", "november",
        "december", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec", "end",
        "half", "quarter", "early", "late", "mid",
    ]

    /// Where the date in a match begins: after any leading words that cannot start one.
    static func dateStart(in match: Substring) -> String.Index {
        var index = match.startIndex
        while index < match.endIndex {
            let rest = match[index...]
            let wordEnd = rest.firstIndex(where: \.isWhitespace) ?? rest.endIndex
            let word = rest[..<wordEnd].lowercased().trimmingCharacters(in: .punctuationCharacters)
            if word.first?.isNumber == true || dateWords.contains(word) || wordEnd == rest.endIndex { return index }
            index = rest[wordEnd...].firstIndex { !$0.isWhitespace } ?? match.endIndex
        }
        return match.startIndex
    }

    /// Moves a date from one clock's today to another's: the same number of days on, at the same
    /// time of day. A date with no time lands at the start of its day.
    static func map(_ date: Date, from source: any ClockService, to target: any ClockService, dateOnly: Bool) -> Date? {
        let sourceCalendar = source.calendar
        let sourceToday = sourceCalendar.startOfDay(for: source.now)
        let days = sourceCalendar.dateComponents([.day], from: sourceToday, to: sourceCalendar.startOfDay(for: date))
            .day
        guard let days else { return nil }
        let calendar = target.calendar
        guard let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: target.now)) else {
            return nil
        }
        if dateOnly { return day }
        let time = sourceCalendar.dateComponents([.hour, .minute], from: date)
        return calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: day)
    }

    /// True when the matched words name a time of day, not only a day.
    static func mentionsTime(_ phrase: Substring) -> Bool {
        let lowered = phrase.lowercased()
        let words = ["noon", "midnight", "morning", "afternoon", "evening", "tonight", "o'clock", "oclock"]
        if words.contains(where: lowered.contains) { return true }
        let characters = Array(lowered)
        for (index, character) in characters.enumerated() where character.isNumber {
            let rest = String(characters[(index + 1)...]).drop { $0 == " " }
            if rest.hasPrefix("am") || rest.hasPrefix("pm") || rest.hasPrefix("a.m") || rest.hasPrefix("p.m")
                || rest.hasPrefix(":") || rest.hasPrefix("h")
            {
                return true
            }
        }
        return false
    }

    /// Words that join a title to its date and mean nothing once the date is gone.
    private static let joiners: Set<String> = ["at", "on", "by", "for", "from", "due", "this", "next", "in", "@"]

    /// The title around the matched date, with the words and marks that joined them dropped.
    static func cleanTitle(_ before: String, _ after: String) -> String {
        func words(_ text: String) -> [String] { text.split(separator: " ").map(String.init) }
        var head = words(before)
        var tail = words(after)
        while let last = head.last, joiners.contains(last.lowercased()) || isMark(last) { head.removeLast() }
        while let first = tail.first, joiners.contains(first.lowercased()) || isMark(first) { tail.removeFirst() }
        let joined = (head + tail).joined(separator: " ")
        return joined.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-\u{2013}\u{2014}"))
    }

    private static func isMark(_ word: String) -> Bool {
        word.allSatisfy { $0.isPunctuation || $0.isSymbol }
    }
}
