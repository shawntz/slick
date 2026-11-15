import Foundation
import Kit
import KitTesting
import Testing

@testable import Schedule

@MainActor
@Suite("Declarations", .timeLimit(.minutes(1)))
struct DeclarationTests {
    typealias F = Fixture

    @Test func theFeatureDeclaresItsCommandsPermissionsAndTrigger() throws {
        let harness = F.harness(F.store())
        #expect(harness.issues.isEmpty)
        #expect(harness.pendingIssues.isEmpty)
        let manifest = ScheduleFeature.manifest
        #expect(manifest.id == "schedule")
        #expect(manifest.isEnabledByDefault)
        #expect(manifest.permissions.map(\.permission) == [.calendars, .reminders])
        for need in manifest.permissions {
            let first = try #require(need.reason.split(separator: " ").first)
            #expect(["Show"].contains(first), "a reason starts with a verb: \(need.reason)")
            #expect(need.reason.hasSuffix("."))
        }
        let commands = harness.feature.commands
        #expect(commands.map(\.id) == ["my-schedule", "create-event", "my-reminders", "create-reminder"])
        #expect(commands.map(\.title) == ["My Schedule", "Create Event", "My Reminders", "Create Reminder"])
        #expect(commands.map(\.requires) == [[.calendars], [.calendars], [.reminders], [.reminders]])
        #expect(commands.allSatisfy { $0.suggestedHotkey == nil && $0.confirmation == nil })
        // Every command shows in root and only opens a list or a form, so deep links may name it.
        #expect(commands.allSatisfy { $0.showsInRoot && $0.allowsDeepLinks })
        #expect(try harness.command("create-event").arguments.map(\.name) == ["event"])
        #expect(try harness.command("create-event").arguments.first?.isOptional == true)
        #expect(try harness.command("create-reminder").arguments.map(\.name) == ["reminder"])
        #expect(harness.feature.suggestionTriggers.map(\.id) == ["meeting-soon"])
        #expect(harness.feature.suggestionTriggers.map(\.namespace) == ["schedule.meeting"])
    }

    @Test func makingAndActivatingReadsNothingAndAsksNothing() async throws {
        let store = F.store(
            events: [F.event("e", "Event", start: F.date(day: 14, 11))], reminders: [F.reminder("r", "R")])
        let harness = F.harness(store)
        _ = harness.feature.commands
        _ = harness.feature.settingsPane
        await harness.activate()
        await harness.deactivate()
        await harness.activate()
        #expect(store.eventQueries.isEmpty)
        #expect(store.createdEvents.isEmpty && store.createdReminders.isEmpty)
        #expect(harness.fakes.permissions.requests.isEmpty)
        #expect(harness.fakes.permissions.openStreamCount == 0)
        #expect(harness.fakes.workspace.opened.isEmpty)
        #expect(harness.fakes.pasteboard.copied.isEmpty)
        try await harness.settle()
    }

    @Test func theSettingsPaneOffersTheExpectedChoices() async throws {
        let store = F.store()
        let harness = F.harness(store)
        let pane = try #require(harness.feature.settingsPane)
        #expect(pane.sections.map(\.title) == ["My Schedule", "Meeting Suggestions", "Reminders", "Access"])
        let items = pane.sections.flatMap(\.items)
        #expect(
            items.compactMap(\.control.key?.name) == [
                "hiddenCalendars", "hidesAllDayEvents", "hidesDeclinedEvents", "range", "suggestsMeetings",
                "meetingLeadTime", "defaultReminderList",
            ])
        #expect(pane.sections.last?.footer == Strings.Settings.privacyNote)
        #expect(Strings.Settings.privacyNote.contains("nothing is sent over the network"))
        let permissions = items.compactMap { item -> Permission? in
            if case .permission(let permission) = item.control { return permission }
            return nil
        }
        #expect(permissions == [.calendars, .reminders])

        // The calendar list is read only when the pane asks, and is empty without access.
        guard case .multiSelect(_, let options) = items[0].control else {
            Issue.record("hidden calendars is not a multi-select")
            return
        }
        #expect(store.eventQueries.isEmpty)
        let choices = await options()
        #expect(choices.map(\.id) == [F.work.id, F.home.id, F.holidays.id])
        #expect(choices.map(\.title) == ["Work", "Home", "Holidays"])
        store.setAccess(.events, granted: false)
        #expect(await options().isEmpty)

        // Defaults are safe: everything shown except declined events, suggestions on at ten minutes.
        let settings = harness.context.settings
        #expect(settings[ScheduleSettings.hiddenCalendars].isEmpty)
        #expect(!settings[ScheduleSettings.hidesAllDayEvents])
        #expect(settings[ScheduleSettings.hidesDeclinedEvents])
        #expect(settings[ScheduleSettings.range] == .week)
        #expect(settings[ScheduleSettings.suggestsMeetings])
        #expect(settings[ScheduleSettings.leadTime] == .tenMinutes)
        #expect(settings[ScheduleSettings.defaultReminderList] == "")
    }

    @Test func calendarsWithTheSameTitleAreToldApartByAccount() {
        let options = EventForm.calendarOptions([
            CalendarInfo(id: "a", title: "Family", account: "iCloud"),
            CalendarInfo(id: "b", title: "Family", account: "Example"),
            CalendarInfo(id: "c", title: "Work", account: "Example"),
        ])
        #expect(options.map(\.title) == ["Family (iCloud)", "Family (Example)", "Work"])
    }

    @Test func userFacingTitlesUseTitleCaseWithoutAFullStop() {
        let titles =
            [
                Strings.Commands.mySchedule, Strings.Commands.createEvent, Strings.Commands.myReminders,
                Strings.Commands.createReminder, Strings.Actions.joinMeeting, Strings.Actions.openInCalendar,
                Strings.Actions.copyDetails, Strings.Actions.copiedDetails, Strings.Actions.copyMeetingLink,
                Strings.Actions.copiedMeetingLink, Strings.Reminders.complete, Strings.Reminders.completed,
                Strings.Reminders.openInReminders, Strings.Reminders.delete, Strings.Reminders.deleted,
                Strings.Schedule.emptyTitle, Strings.Reminders.emptyTitle, Strings.Forms.eventCreated,
                Strings.Forms.reminderCreated, Strings.Failure.notFound, Strings.Failure.saveFailed,
                Strings.Failure.readOnly, Strings.Failure.noCalendar, Strings.Forms.noWritableCalendar,
                Strings.Forms.noWritableList, Strings.Access.title(.calendars), Strings.Access.grant(.reminders),
                Strings.Failure.calendarGone, Strings.Reminders.deleteQuestion(""),
            ] + ReminderGroup.allCases.map(Strings.Reminders.section)
        let small: Set<String> = ["in", "to", "of", "and", "the", "a", "for", "on"]
        for title in titles {
            #expect(!title.hasSuffix("."), "\(title)")
            for word in title.split(separator: " ") where !small.contains(String(word)) {
                #expect(word.first?.isUppercase == true || word.first?.isNumber == true, "\(title)")
            }
        }
        let sentences = [
            Strings.Reminders.emptyMessage, Strings.Reminders.deleteMessage, Strings.Failure.notFoundReason,
            Strings.Settings.hiddenCalendarsInfo, Strings.Settings.leadTimeInfo, Strings.Settings.privacyNote,
            Strings.Schedule.emptyMessage(7), Strings.Access.message(.calendars), Strings.Failure.calendarGoneReason,
            Strings.Settings.calendarsInfo, Strings.Settings.remindersInfo,
        ]
        for sentence in sentences {
            #expect(sentence.hasSuffix("."), "\(sentence)")
            #expect(!sentence.contains("\u{2014}"), "no em dashes: \(sentence)")
        }
    }

    @Test func providerNamesAreKnown() {
        for provider in MeetingProvider.allCases {
            #expect(!provider.name.isEmpty)
        }
    }

    @Test func linksToTheAppsAreWellFormed() {
        #expect(
            CalendarAppLinks.event(externalID: "ABC-123:DEF/456", eventID: "x")?.absoluteString
                == "ical://ekevent/ABC-123:DEF%2F456?method=show&options=more")
        #expect(
            CalendarAppLinks.event(externalID: nil, eventID: "local-1")?.absoluteString
                == "ical://ekevent/local-1?method=show&options=more")
        #expect(CalendarAppLinks.event(externalID: "", eventID: "") == nil)
        #expect(CalendarAppLinks.reminder(id: "R-1")?.absoluteString == "x-apple-reminderkit://REMCDReminder/R-1")
        #expect(CalendarAppLinks.reminder(id: "") == nil)
    }

    @Test func oneLineCleansTitles() {
        #expect(OneLine.clean("  Two\nlines\t here ") == "Two lines here")
        #expect(OneLine.clean("\u{0007}bell") == "bell")
        #expect(OneLine.clean(String(repeating: "a", count: 300), limit: 10) == "aaaaaaaaaa\u{2026}")
        #expect(OneLine.clean("") == "")
    }

    @Test func priorityFollowsEventKitsScale() {
        #expect(
            (0...9).map { ReminderPriority(eventKitValue: $0) } == [
                .none, .high, .high, .high, .high, .medium, .low, .low, .low, .low,
            ])
        #expect(ReminderPriority(eventKitValue: 42) == .none)
    }
}
