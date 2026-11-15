import Foundation
import Kit
import KitTesting
import Testing

@testable import Schedule

@MainActor
@Suite("Meeting suggestion", .timeLimit(.minutes(1)))
struct MeetingSuggestionTests {
    typealias F = Fixture

    /// A meeting with a Meet link at 10:00, half an hour after the fake clock's start.
    static let meetingStart = Fixture.date(day: 14, 10)

    static func meeting(_ id: String = "standup", start: Date = meetingStart, notes: String? = Fixture.meetLink)
        -> EventOccurrence
    {
        F.event(id, "Stand-up", start: start, minutes: 15, notes: notes)
    }

    @Test func theWindowRunsFromTheLeadTimeUntilFiveMinutesAfterTheStart() async throws {
        let store = F.store(events: [Self.meeting()])
        let harness = F.harness(store)
        let start = Self.meetingStart
        #expect(harness.issues.isEmpty)

        #expect(try await harness.suggestions(at: start.addingTimeInterval(-601)).isEmpty)
        #expect(store.eventQueries.last == start.addingTimeInterval(-901)...start.addingTimeInterval(0))

        let opening = try #require(try await harness.suggestions(at: start.addingTimeInterval(-600)).first)
        #expect(opening.urgency.value(at: start.addingTimeInterval(-600)) == 0)
        #expect(!opening.isImminent(at: start.addingTimeInterval(-600)))
        #expect(opening.urgency.value(at: start.addingTimeInterval(-450)) == 0.5)

        let fiveBefore = try #require(try await harness.suggestions(at: start.addingTimeInterval(-300)).first)
        #expect(fiveBefore.urgency.value(at: start.addingTimeInterval(-300)) == 1)
        #expect(fiveBefore.isImminent(at: start.addingTimeInterval(-300)))

        #expect(try await harness.suggestions(at: start).count == 1)
        #expect(try await harness.suggestions(at: start.addingTimeInterval(299)).count == 1)
        #expect(try await harness.suggestions(at: start.addingTimeInterval(300)).isEmpty)
        #expect(opening.id == fiveBefore.id, "one situation, one ID")
        #expect(opening.id == "standup@\(Int(start.timeIntervalSince1970))")
    }

    @Test func theRowJoinsAndIsNeverRemembered() async throws {
        let harness = F.harness(F.store(events: [Self.meeting()]))
        let suggestion = try #require(
            try await harness.suggestions(at: Self.meetingStart.addingTimeInterval(-120)).first)
        let row = suggestion.row
        #expect(row.id.namespace == "schedule.meeting")
        #expect(row.title == "Join Stand-up")
        #expect(row.subtitle == "Opens the call in Google Meet")
        #expect(row.memory == .never)
        #expect(row.expires == Self.meetingStart.addingTimeInterval(300))
        #expect(suggestion.expires == row.expires)

        let remembered = try JSONDecoder().decode(Row.self, from: JSONEncoder().encode(row))
        #expect(harness.rootActions(for: remembered).map(\.id) == ["join", "open-in-calendar", "copy-link"])
        try await harness.performRoot("join", on: remembered)
        #expect(harness.fakes.workspace.opened == [URL(string: F.meetLink)])
        #expect(harness.issues.isEmpty)
    }

    @Test func onlyMeetingsWithALinkThatTheUserMayJoinAreSuggested() async throws {
        let start = Self.meetingStart
        let store = F.store(events: [
            Self.meeting("no-link", notes: "Room 4"),
            F.event(
                "all-day", "Offsite", start: F.date(day: 14, 0), allDay: true, notes: F.meetLink,
                end: F.date(day: 15, 0)),
            F.event("declined", "Declined", start: start, notes: F.zoomLink, attendance: .declined),
            F.event("canceled", "Canceled", start: start, notes: F.zoomLink, canceled: true),
            F.event("home", "Home call", start: start, calendar: F.home, notes: F.zoomLink),
            F.event("tentative", "Maybe", start: start, notes: F.zoomLink, attendance: .tentative),
        ])
        let harness = F.harness(store)
        harness.context.settings[ScheduleSettings.hiddenCalendars] = [F.home.id]
        let titles = try await harness.suggestions(at: start.addingTimeInterval(-60)).map(\.row.title)
        #expect(titles == ["Join Maybe"])
    }

    @Test func theLeadTimeSettingMovesTheWindow() async throws {
        let harness = F.harness(F.store(events: [Self.meeting()]))
        harness.context.settings[ScheduleSettings.leadTime] = .twoMinutes
        let start = Self.meetingStart
        #expect(try await harness.suggestions(at: start.addingTimeInterval(-121)).isEmpty)
        let suggestion = try #require(try await harness.suggestions(at: start.addingTimeInterval(-120)).first)
        #expect(suggestion.urgency.value(at: start.addingTimeInterval(-120)) == 1)
        #expect(suggestion.isImminent(at: start.addingTimeInterval(-120)))

        harness.context.settings[ScheduleSettings.leadTime] = .fifteenMinutes
        #expect(try await harness.suggestions(at: start.addingTimeInterval(-900)).count == 1)
    }

    @Test func theSuggestionCanBeTurnedOff() async throws {
        let store = F.store(events: [Self.meeting()])
        let harness = F.harness(store)
        harness.context.settings[ScheduleSettings.suggestsMeetings] = false
        #expect(try await harness.suggestions(at: Self.meetingStart).isEmpty)
        #expect(store.eventQueries.isEmpty, "a switched-off suggestion reads nothing")
    }

    @Test func withoutAccessNothingIsSuggestedAndNothingAsks() async throws {
        let store = F.store(events: [Self.meeting()])
        let harness = F.harness(store, fakes: FakeServices(permissions: .notDetermined))
        #expect(try await harness.suggestions(at: Self.meetingStart).isEmpty)
        #expect(store.eventQueries.isEmpty)
        #expect(harness.fakes.permissions.requests.isEmpty)
        #expect(harness.fakes.permissions.openStreamCount == 0)
    }

    @Test func aStoreFailureThrowsSoRootKeepsWhatItHad() async throws {
        let store = F.store(events: [Self.meeting()])
        store.setAccess(.events, granted: false)
        let harness = F.harness(store)
        await #expect(throws: ScheduleError.accessMissing(.calendars)) {
            _ = try await harness.suggestions(at: Self.meetingStart)
        }
    }

    @Test func theTriggerReloadsOnTheStoreAndItsSettings() {
        let store = F.store()
        let harness = F.harness(store)
        let trigger = harness.feature.suggestionTriggers[0]
        #expect(trigger.changes === store.changes)
        #expect(trigger.requires == [.calendars])
        #expect(trigger.refreshInterval == .seconds(60))
        #expect(
            Set(trigger.reloadsOnSettings.map(\.name)) == ["suggestsMeetings", "meetingLeadTime", "hiddenCalendars"])
    }

    @Test func twoMeetingsAtOnceAreBothOffered() async throws {
        let start = Self.meetingStart
        let harness = F.harness(
            F.store(events: [
                Self.meeting("a", start: start),
                Self.meeting("b", start: start.addingTimeInterval(240), notes: F.zoomLink),
            ]))
        let suggestions = try await harness.suggestions(at: start.addingTimeInterval(-60))
        #expect(
            suggestions.map(\.id) == [
                "a@\(Int(start.timeIntervalSince1970))", "b@\(Int(start.timeIntervalSince1970) + 240)",
            ])
    }
}
