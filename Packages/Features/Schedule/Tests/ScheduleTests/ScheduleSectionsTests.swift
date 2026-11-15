import Foundation
import Kit
import KitTesting
import Testing

@testable import Schedule

@Suite("My Schedule sections", .timeLimit(.minutes(1)))
struct ScheduleSectionsTests {
    typealias F = Fixture

    private func titles(_ sections: [ListSection]) -> [String] {
        sections.map { $0.title ?? "" }
    }

    private func rows(_ sections: [ListSection]) -> [[String]] {
        sections.map { $0.rows.map(\.title) }
    }

    @Test func eventsGroupByDayFromTodayWithAllDayFirst() {
        let events = [
            F.event("b", "Review", start: F.date(day: 14, 15)),
            F.event("a", "Stand-up", start: F.date(day: 14, 10)),
            F.event("h", "Holiday", start: F.date(day: 14, 0), allDay: true, end: F.date(day: 15, 0)),
            F.event("c", "Planning", start: F.date(day: 15, 9)),
            F.event("d", "Retro", start: F.date(day: 16, 11)),
            F.event("e", "Next week", start: F.date(day: 20, 11)),
        ]
        let sections = EventRows.build(events, options: ScheduleOptions(), clock: F.clock(F.start))
        #expect(titles(sections) == ["Today", "Tomorrow", "Monday", "Friday"])
        #expect(rows(sections) == [["Holiday", "Stand-up", "Review"], ["Planning"], ["Retro"], ["Next week"]])
        #expect(sections.map(\.id) == ["2026-11-14", "2026-11-15", "2026-11-16", "2026-11-20"])
    }

    @Test func endedEventsLeaveAndRunningOnesStay() {
        let events = [
            F.event("past", "Breakfast", start: F.date(day: 14, 8), minutes: 60),
            F.event("running", "Workshop", start: F.date(day: 14, 9), minutes: 60),
            F.event("ends-now", "Early call", start: F.date(day: 14, 9), end: F.start),
        ]
        let sections = EventRows.build(events, options: ScheduleOptions(), clock: F.clock(F.start))
        #expect(rows(sections) == [["Workshop"]])
        let row = sections[0].rows[0]
        #expect(row.accessories.contains(.tag(Strings.Schedule.now, color: .green)))
        #expect(plain(row.subtitle) == "9:00 AM \u{2013} 10:00 AM")
    }

    @Test func theRangeEndsAfterTheChosenNumberOfDays() {
        let events = [
            F.event("in", "Day six", start: F.date(day: 20, 23, 30)),
            F.event("out", "Day seven", start: F.date(day: 21, 0, 0)),
        ]
        let week = EventRows.build(events, options: ScheduleOptions(days: 7), clock: F.clock(F.start))
        #expect(rows(week) == [["Day six"]])
        let threeDays = EventRows.build(events, options: ScheduleOptions(days: 3), clock: F.clock(F.start))
        #expect(threeDays.isEmpty)
        let range = EventRows.range(clock: F.clock(F.start), days: 7)
        #expect(range.start == F.start)
        #expect(range.end == F.date(day: 21, 0))
    }

    @Test func crossingMidnightMovesTomorrowToToday() {
        let clock = F.clock(F.date(day: 14, 23, 50))
        let events = [
            F.event("late", "Late call", start: F.date(day: 14, 23, 30), minutes: 40),
            F.event("early", "Early run", start: F.date(day: 15, 7)),
            F.event("monday", "Planning", start: F.date(day: 16, 9)),
        ]
        let before = EventRows.build(events, options: ScheduleOptions(), clock: clock)
        #expect(titles(before) == ["Today", "Tomorrow", "Monday"])
        // The late call runs past midnight, so it also ends on Sunday.
        #expect(rows(before) == [["Late call"], ["Late call", "Early run"], ["Planning"]])
        #expect(plain(before[1].rows[0].subtitle) == "Ends at 12:10 AM")

        clock.advance(by: .seconds(20 * 60))  // 00:10 on Sunday
        let after = EventRows.build(events, options: ScheduleOptions(), clock: clock)
        #expect(titles(after) == ["Today", "Tomorrow"])
        #expect(rows(after) == [["Early run"], ["Planning"]])
        #expect(after.map(\.id) == ["2026-11-15", "2026-11-16"])
    }

    @Test func aTimeZoneChangeMovesEventsBetweenDays() {
        // 03:00 UTC on Sunday is still Saturday evening in Los Angeles and Sunday noon in Tokyo.
        let events = [F.event("call", "Call", start: F.date(day: 15, 3))]
        let utc = EventRows.build(events, options: ScheduleOptions(), clock: F.clock(F.start))
        #expect(titles(utc) == ["Tomorrow"])
        #expect(plain(utc[0].rows[0].subtitle) == "3:00 AM \u{2013} 3:30 AM")

        let losAngeles = EventRows.build(
            events, options: ScheduleOptions(), clock: F.clock(F.start, timeZone: "America/Los_Angeles"))
        #expect(titles(losAngeles) == ["Today"])
        #expect(losAngeles[0].id == "2026-11-14")
        #expect(plain(losAngeles[0].rows[0].subtitle) == "7:00 PM \u{2013} 7:30 PM")

        let tokyo = EventRows.build(events, options: ScheduleOptions(), clock: F.clock(F.start, timeZone: "Asia/Tokyo"))
        #expect(titles(tokyo) == ["Tomorrow"])
        #expect(plain(tokyo[0].rows[0].subtitle) == "12:00 PM \u{2013} 12:30 PM")
    }

    @Test func aDaylightSavingNightStillGivesOneSectionPerDay() {
        // Clocks in New York go back an hour early on 1 November 2026, so that day has 25 hours.
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt
        func at(_ day: Int, _ hour: Int, month: Int = 11) -> Date {
            newYork.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour)) ?? F.start
        }
        let october31 = F.clock(at(31, 20, month: 10), timeZone: "America/New_York")
        let events = [
            F.event("a", "Before the change", start: at(1, 0), minutes: 30),
            F.event("b", "After the change", start: at(1, 23), minutes: 30),
            F.event("c", "Monday", start: at(2, 9), minutes: 30),
        ]
        let sections = EventRows.build(events, options: ScheduleOptions(), clock: october31)
        #expect(titles(sections) == ["Tomorrow", "Monday"])
        #expect(rows(sections) == [["Before the change", "After the change"], ["Monday"]])
    }

    @Test func aMultiDayEventShowsOnEachDayItCovers() {
        let events = [
            F.event("trip", "Conference", start: F.date(day: 13, 10), end: F.date(day: 16, 12)),
            F.event("fest", "Festival", start: F.date(day: 15, 0), allDay: true, end: F.date(day: 17, 0)),
            F.event("night", "Night shift", start: F.date(day: 14, 22), end: F.date(day: 15, 6)),
            F.event("to-midnight", "Ends at midnight", start: F.date(day: 14, 22), end: F.date(day: 15, 0)),
        ]
        let entries = EventRows.entries(events, options: ScheduleOptions(), clock: F.clock(F.start))
        let conference = entries.filter { $0.event.eventID == "trip" }
        #expect(conference.map(\.index) == [1, 2, 3])
        #expect(conference.allSatisfy { $0.dayCount == 4 })
        #expect(entries.filter { $0.event.eventID == "fest" }.map(\.index) == [0, 1])
        #expect(entries.filter { $0.event.eventID == "night" }.map(\.index) == [0, 1])
        #expect(entries.filter { $0.event.eventID == "to-midnight" }.count == 1, "midnight is not a second day")

        let sections = EventRows.build(events, options: ScheduleOptions(), clock: F.clock(F.start))
        let subtitles = sections.map { section in section.rows.map { "\($0.title): \(plain($0.subtitle))" } }
        #expect(
            subtitles == [
                [
                    "Conference: Continues all day", "Ends at midnight: 10:00 PM \u{2013} 12:00 AM",
                    "Night shift: Starts at 10:00 PM",
                ],
                ["Festival: All day, day 1 of 2", "Conference: Continues all day", "Night shift: Ends at 6:00 AM"],
                ["Festival: All day, day 2 of 2", "Conference: Ends at 12:00 PM"],
            ])
        // One event keeps one row ID on every day.
        #expect(Set(sections.flatMap(\.rows).filter { $0.title == "Conference" }.map(\.id)).count == 1)
    }

    @Test func recurringOccurrencesEachGetTheirOwnStableRow() {
        let occurrences = (14...18).map { day in
            F.event("weekly", "Stand-up", start: F.date(day: day, 10), recurring: true)
        }
        let sections = EventRows.build(occurrences, options: ScheduleOptions(), clock: F.clock(F.start))
        let ids = sections.flatMap(\.rows).map(\.id.rawValue)
        #expect(ids.count == 5)
        #expect(Set(ids).count == 5)
        #expect(ids.first == "schedule.event:weekly@\(Int(F.date(day: 14, 10).timeIntervalSince1970))")
        // The same occurrence gets the same ID on another load.
        let again = EventRows.build(occurrences.reversed(), options: ScheduleOptions(), clock: F.clock(F.start))
        #expect(again.flatMap(\.rows).map(\.id.rawValue) == ids)
    }

    @Test func settingsHideCalendarsAllDayAndDeclinedEvents() {
        let events = [
            F.event("w", "Work thing", start: F.date(day: 14, 11)),
            F.event("h", "Home thing", start: F.date(day: 14, 12), calendar: F.home),
            F.event("ad", "Birthday", start: F.date(day: 14, 0), allDay: true, end: F.date(day: 15, 0)),
            F.event("no", "Declined thing", start: F.date(day: 14, 13), attendance: .declined),
            F.event("x", "Canceled thing", start: F.date(day: 14, 14), canceled: true),
        ]
        let defaults = EventRows.build(events, options: ScheduleOptions(), clock: F.clock(F.start))
        #expect(rows(defaults) == [["Birthday", "Work thing", "Home thing", "Canceled thing"]])

        let everything = EventRows.build(
            events, options: ScheduleOptions(hidesDeclinedEvents: false), clock: F.clock(F.start))
        #expect(everything[0].rows.map(\.title).contains("Declined thing"))
        let declined = everything[0].rows.first { $0.title == "Declined thing" }
        #expect(declined?.accessories.contains(.tag(Strings.Schedule.declined, color: .gray)) == true)

        let trimmed = EventRows.build(
            events, options: ScheduleOptions(hiddenCalendars: [F.home.id], hidesAllDayEvents: true),
            clock: F.clock(F.start))
        #expect(rows(trimmed) == [["Work thing", "Canceled thing"]])
        #expect(trimmed[0].rows[1].accessories.contains(.tag(Strings.Schedule.canceled, color: .red)))
    }

    @Test func rowsShowTheTimeColorPlaceAndMeetingService() throws {
        let events = [
            F.event(
                "m", "Design Review", start: F.date(day: 14, 11), location: "Room 4\nSecond floor",
                notes: "Join: \(F.meetLink)"),
            F.event("z", "  ", start: F.date(day: 14, 12), location: F.zoomLink),
        ]
        let sections = EventRows.build(events, options: ScheduleOptions(), clock: F.clock(F.start))
        let review = try #require(sections.first?.rows.first)
        #expect(review.title == "Design Review")
        #expect(plain(review.subtitle) == "11:00 AM \u{2013} 11:30 AM")
        #expect(review.icon == .symbol("circle.fill", tint: F.work.color))
        #expect(
            review.accessories == [.icon(.symbol("video.fill"), tooltip: "Google Meet"), .text("Room 4 Second floor")])
        #expect(review.keywords.contains("Work") && review.keywords.contains("Google Meet"))
        #expect(review.summary?.link?.url.absoluteString == F.meetLink)

        let untitled = try #require(sections.first?.rows.last)
        #expect(untitled.title == Strings.Schedule.untitled)
        #expect(untitled.accessories == [.icon(.symbol("video.fill"), tooltip: "Zoom")], "a link is not a place")
    }

    @Test func aPayloadStaysSmallAndSurvivesASnapshot() throws {
        let longTitle = String(repeating: "Quarterly planning with everyone ", count: 30)
        let event = F.event(
            "long", longTitle, start: F.date(day: 14, 11), location: String(repeating: "Building 7, ", count: 50),
            notes: TeamsText.invitation)
        let row = try #require(
            EventRows.build([event], options: ScheduleOptions(), clock: F.clock(F.start)).first?.rows.first)
        let data = try JSONEncoder().encode(row.payload)
        #expect(data.count < 1_024, "payload is \(data.count) bytes")
        let rebuilt = try JSONDecoder().decode(Row.self, from: JSONEncoder().encode(row))
        #expect(rebuilt.summary == row.summary)
        #expect(rebuilt.summary?.link?.provider == .teams)
    }
}

/// Formatted times put a narrow no-break space before AM and PM. Tests write a plain space.
nonisolated func plain(_ text: String?) -> String {
    (text ?? "").replacingOccurrences(of: "\u{202F}", with: " ")
}

/// A Teams invitation for tests that need a long link.
enum TeamsText {
    static let invitation = MeetingLinkFinderTests.teamsInvitation
}
