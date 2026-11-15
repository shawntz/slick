import Foundation
import Kit
import KitTesting
import Testing

@testable import Schedule

/// The parser maps what NSDataDetector found from the system's today to the fake clock's, so these
/// phrases name days relative to today. A weekday or a calendar date would depend on the day the
/// tests run.
@Suite("Natural language", .timeLimit(.minutes(1)))
nonisolated struct NaturalLanguageTests {
    typealias F = Fixture

    struct Phrase: CustomTestStringConvertible, Sendable {
        let text: String
        let title: String
        let date: Date?
        let dateOnly: Bool
        let minutes: Int?

        init(_ text: String, _ title: String, _ date: Date?, dateOnly: Bool = false, minutes: Int? = nil) {
            self.text = text
            self.title = title
            self.date = date
            self.dateOnly = dateOnly
            self.minutes = minutes
        }

        var testDescription: String { text }
    }

    static let phrases: [Phrase] = [
        Phrase("Lunch tomorrow at 1pm", "Lunch", Fixture.date(day: 15, 13)),
        Phrase("Dinner tonight at 7", "Dinner", Fixture.date(day: 14, 19)),
        Phrase("Dentist at 3pm tomorrow", "Dentist", Fixture.date(day: 15, 15)),
        Phrase("Call the bank tomorrow at 10am", "Call the bank", Fixture.date(day: 15, 10)),
        Phrase("Standup tomorrow 9:15", "Standup", Fixture.date(day: 15, 9, 15)),
        Phrase("Review today from 2pm to 3:30pm", "Review", Fixture.date(day: 14, 14), minutes: 90),
        Phrase("Gym in 2 days at 6pm", "Gym", Fixture.date(day: 16, 18)),
        Phrase("Pay rent tomorrow", "Pay rent", Fixture.date(day: 15, 0), dateOnly: true),
        Phrase("tomorrow at 9am", "", Fixture.date(day: 15, 9)),
        Phrase("Buy milk", "Buy milk", nil),
        Phrase("  Buy\nmilk  ", "Buy milk", nil),
    ]

    @Test(arguments: phrases)
    func readsThePhrase(_ phrase: Phrase) async {
        let parsed = await NaturalLanguage.parse(phrase.text, clock: FrozenClock(FakeClock()))
        #expect(parsed.title == phrase.title)
        #expect(parsed.date == phrase.date)
        #expect(parsed.isDateOnly == phrase.dateOnly)
        #expect(parsed.duration.map { Int($0 / 60) } == phrase.minutes)
    }

    @Test func aWeekdayKeepsItsTitleAndTime() async throws {
        let parsed = await NaturalLanguage.parse("Call mom on Friday at 10am", clock: FrozenClock(FakeClock()))
        #expect(parsed.title == "Call mom")
        let date = try #require(parsed.date)
        let parts = Fixture.utc.dateComponents([.hour, .minute], from: date)
        #expect(parts.hour == 10 && parts.minute == 0)
        #expect(date > Fixture.start)
    }

    @Test func emptyAndOddTextIsSafe() async {
        let clock = FrozenClock(FakeClock())
        #expect(await NaturalLanguage.parse("", clock: clock) == .empty)
        #expect(await NaturalLanguage.parse("   \n ", clock: clock) == .empty)
        let long = await NaturalLanguage.parse(String(repeating: "word ", count: 5_000), clock: clock)
        #expect(long.title.count <= NaturalLanguage.limit + 1)
        for text in [
            "\u{0000}", "\u{202E}tomorrow", "\u{1F600} tomorrow at 1pm", "at", "on on on", "12345678901234567890",
        ] {
            _ = await NaturalLanguage.parse(text, clock: clock)
        }
    }

    @Test func mappingMovesDaysAndTimeFromOneClockToAnother() throws {
        // The detector ran on a Friday evening in Los Angeles; the feature's clock is Saturday morning in UTC.
        let detector = F.clock(F.date(day: 20, 18, timeZone: "America/Los_Angeles"), timeZone: "America/Los_Angeles")
        let found = F.date(day: 21, 13, timeZone: "America/Los_Angeles")  // "tomorrow at 1pm" there
        let target = F.clock(F.start)
        #expect(NaturalLanguage.map(found, from: detector, to: target, dateOnly: false) == F.date(day: 15, 13))
        #expect(NaturalLanguage.map(found, from: detector, to: target, dateOnly: true) == F.date(day: 15, 0))
        // With the same clock on both sides nothing moves, which is the app's case.
        #expect(NaturalLanguage.map(found, from: detector, to: detector, dateOnly: false) == found)
    }

    @Test func timeWordsAreToldApartFromDayWords() {
        for phrase in ["at 3pm", "3 pm", "15:00", "noon", "tonight", "10 a.m.", "tomorrow morning", "9h30"] {
            #expect(NaturalLanguage.mentionsTime(Substring(phrase)), "\(phrase)")
        }
        for phrase in ["tomorrow", "on Friday", "December 3", "the 3rd", "next week", "in 2 days"] {
            #expect(!NaturalLanguage.mentionsTime(Substring(phrase)), "\(phrase)")
        }
    }

    @Test func joiningWordsAreDroppedFromTheTitle() {
        #expect(NaturalLanguage.cleanTitle("Call the bank on ", "") == "Call the bank")
        #expect(NaturalLanguage.cleanTitle("", " for the standup") == "the standup")
        #expect(NaturalLanguage.cleanTitle("Review - ", "") == "Review")
        #expect(NaturalLanguage.cleanTitle("Lunch ", ", with the team") == "Lunch with the team")
        #expect(NaturalLanguage.cleanTitle("", "") == "")
    }

    @Test func leadingWordsThatCannotStartADateStayInTheTitle() {
        let match: Substring = "Lunch tomorrow at 1pm"
        #expect(match[NaturalLanguage.dateStart(in: match)...] == "tomorrow at 1pm")
        let plain: Substring = "tomorrow at 1pm"
        #expect(NaturalLanguage.dateStart(in: plain) == plain.startIndex)
        let numeric: Substring = "Team 3pm"
        #expect(numeric[NaturalLanguage.dateStart(in: numeric)...] == "3pm")
        let single: Substring = "Lunch"
        #expect(NaturalLanguage.dateStart(in: single) == single.startIndex)
    }
}
