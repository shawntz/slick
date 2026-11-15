import Foundation
import Kit
import KitTesting
import Testing

@testable import Schedule

@MainActor
@Suite("My Reminders", .timeLimit(.minutes(1)))
struct ReminderTests {
    typealias F = Fixture

    static let reminders = [
        F.reminder("old", "Water the plants", due: F.date(day: 12, 0), hasTime: false),
        F.reminder("morning", "Morning pages", due: F.date(day: 14, 8)),
        F.reminder("afternoon", "Send the invoice", due: F.date(day: 14, 15), priority: .high),
        F.reminder("today", "Tidy the desk", due: F.date(day: 14, 0), hasTime: false, list: F.errands),
        F.reminder("tomorrow", "Renew the library card", due: F.date(day: 15, 0), hasTime: false, list: F.errands),
        F.reminder(
            "december", "Book the trip", due: Fixture.utc.date(byAdding: .day, value: 36, to: F.date(day: 14, 10))),
        F.reminder("whenever", "Learn to juggle"),
        F.reminder("someday", "Fix the bike", priority: .medium, list: F.errands, notes: "Back wheel squeaks"),
    ]

    @Test func remindersGroupIntoOverdueTodayUpcomingAndUndated() {
        let sections = ReminderRows.build(Self.reminders, listID: nil, clock: F.clock(F.start))
        #expect(sections.map(\.id) == ["overdue", "today", "upcoming", "undated"])
        #expect(sections.map(\.title) == ["Overdue", "Today", "Upcoming", "No Due Date"])
        let shown = sections.map { $0.rows.map { "\($0.title): \(plain($0.subtitle))" } }
        #expect(
            shown == [
                ["Water the plants: Thursday", "Morning pages: Today at 8:00 AM"],
                ["Tidy the desk: Today", "Send the invoice: Today at 3:00 PM"],
                ["Renew the library card: Tomorrow", "Book the trip: Sunday, December 20 at 10:00 AM"],
                ["Fix the bike: ", "Learn to juggle: "],
            ])
        let overdue = sections[0].rows[1]
        #expect(overdue.subtitleColor == .red)
        #expect(overdue.icon == .symbol("exclamationmark.circle", tint: .gray))
        let invoice = sections[1].rows[1]
        #expect(invoice.subtitleColor == nil)
        #expect(invoice.accessories == [.text("!!!", color: .orange), .tag("Inbox", color: nil)])
        #expect(sections[3].rows[0].keywords.contains("Back wheel squeaks"))
    }

    @Test func crossingMidnightMovesTodayToOverdueAndTomorrowToToday() {
        let clock = F.clock(F.date(day: 14, 23, 50))
        let reminders = [
            F.reminder("day", "Tidy the desk", due: F.date(day: 14, 0), hasTime: false),
            F.reminder("timed", "Call the plumber", due: F.date(day: 15, 8)),
        ]
        let before = ReminderRows.build(reminders, listID: nil, clock: clock)
        #expect(before.map(\.id) == ["today", "upcoming"])
        #expect(plain(before[1].rows[0].subtitle) == "Tomorrow at 8:00 AM")
        clock.advance(by: .seconds(20 * 60))
        let after = ReminderRows.build(reminders, listID: nil, clock: clock)
        #expect(after.map(\.id) == ["overdue", "today"])
        #expect(after[0].rows[0].subtitle == "Yesterday")
        #expect(plain(after[1].rows[0].subtitle) == "Today at 8:00 AM")
    }

    @Test func aTimeZoneChangeMovesADueTimeBetweenDays() {
        let reminders = [F.reminder("call", "Call the office", due: F.date(day: 15, 3))]
        #expect(ReminderRows.build(reminders, listID: nil, clock: F.clock(F.start)).map(\.id) == ["upcoming"])
        let losAngeles = ReminderRows.build(
            reminders, listID: nil, clock: F.clock(F.start, timeZone: "America/Los_Angeles"))
        #expect(losAngeles.map(\.id) == ["today"])
        #expect(plain(losAngeles[0].rows[0].subtitle) == "Today at 7:00 PM")
    }

    @Test func theListOpensWithADropdownOfLists() async throws {
        let store = F.store(reminders: Self.reminders)
        let harness = F.harness(store)
        #expect(harness.issues.isEmpty)
        try await harness.run("my-reminders")
        #expect(harness.page?.dropdown?.options.map(\.id) == ["all", F.archive.id, F.errands.id, F.inbox.id])
        #expect(harness.rows.count == Self.reminders.count)
        try await harness.setFilter(F.errands.id)
        #expect(harness.rows.map(\.title) == ["Tidy the desk", "Renew the library card", "Fix the bike"])
        try await harness.setQuery("bike")
        #expect(harness.rows.map(\.title) == ["Fix the bike"])
        #expect(harness.actions().map(\.id) == ["complete", "open-in-reminders", "delete"])
        #expect(harness.issues.isEmpty)
    }

    @Test func completeRemovesTheReminderAndSaysSo() async throws {
        let store = F.store(reminders: Self.reminders)
        let harness = F.harness(store)
        try await harness.run("my-reminders")
        try harness.select(title: "Send the invoice")
        let outcome = try await harness.performPrimary()
        #expect(outcome.kind == .keepOpen)
        #expect(store.completedReminderIDs == ["afternoon"])
        #expect(harness.toasts.last?.title == "Reminder Completed")
        #expect(!harness.rows.map(\.title).contains("Send the invoice"), "the list follows the store")
    }

    @Test func deleteAsksFirstAndDoesNothingWhenDeclined() async throws {
        let store = F.store(reminders: Self.reminders)
        let harness = F.harness(store)
        try await harness.run("my-reminders")
        try harness.select(title: "Water the plants")
        let delete = try #require(harness.actions().first { $0.id == "delete" })
        #expect(delete.style == .destructive)
        #expect(delete.shortcut == .remove)
        #expect(delete.confirmation?.isDestructive == true)

        harness.confirmationAnswer = false
        try await harness.perform("delete")
        #expect(store.deletedReminderIDs.isEmpty)
        #expect(harness.confirmations.last?.title == "Delete \u{201C}Water the plants\u{201D}?")
        #expect(harness.confirmations.last?.message == Strings.Reminders.deleteMessage)

        harness.confirmationAnswer = true
        try await harness.perform("delete")
        #expect(store.deletedReminderIDs == ["old"])
        #expect(harness.toasts.last?.title == "Reminder Deleted")
        #expect(!harness.rows.map(\.title).contains("Water the plants"))
    }

    @Test func openInRemindersShowsTheReminderOrOpensReminders() async throws {
        let harness = F.harness(F.store(reminders: Self.reminders))
        try await harness.run("my-reminders")
        try harness.select(title: "Learn to juggle")
        try await harness.perform("open-in-reminders")
        #expect(harness.fakes.workspace.opened == [URL(string: "x-apple-reminderkit://REMCDReminder/whenever")])
        harness.fakes.workspace.failsToOpen = true
        try await harness.perform("open-in-reminders")
        #expect(harness.fakes.workspace.launched == ["com.apple.reminders"])
    }

    @Test func aReminderGoneElsewhereSaysSo() async throws {
        let store = F.store(reminders: Self.reminders)
        let harness = F.harness(store)
        try await harness.run("my-reminders")
        try harness.select(title: "Learn to juggle")
        try await store.complete(reminderID: "whenever")  // done on another device
        harness.throwsActionErrors = false
        try await harness.perform("complete")
        #expect(harness.toasts.last?.title == "Reminder Not Found")
        #expect(harness.toasts.last?.message == Strings.Failure.notFoundReason)
    }

    @Test func remindersAreAskedForOnlyWhenRun() async throws {
        let store = F.store(reminders: Self.reminders)
        let harness = F.harness(store, fakes: FakeServices(permissions: .notDetermined))
        await harness.activate()
        await #expect(throws: HarnessError.permissionRequired([.reminders])) { try await harness.run("my-reminders") }
        #expect(harness.fakes.permissions.requests.isEmpty)
        harness.grantsMissingPermissions = true
        try await harness.run("my-reminders")
        #expect(harness.fakes.permissions.requests == [.reminders])
    }

    @Test func accessLostAtActionTimeAsksAgain() async throws {
        let store = F.store(reminders: Self.reminders)
        let harness = F.harness(store)
        try await harness.run("my-reminders")
        store.setAccess(.reminders, granted: false)
        await #expect(throws: HarnessError.permissionRequired([.reminders])) { try await harness.performPrimary() }
        #expect(store.completedReminderIDs.isEmpty)
        await #expect(throws: HarnessError.permissionRequired([.reminders])) { try await harness.run("my-reminders") }
    }

    @Test func anEmptyListOffersCreateReminder() async throws {
        let harness = F.harness(F.store())
        try await harness.run("my-reminders")
        #expect(harness.rows.isEmpty)
        #expect(harness.page?.emptyState?.title == "No Reminders")
        #expect(harness.actions().map(\.id) == ["run.cmd:schedule.create-reminder"])
        try await harness.perform("run.cmd:schedule.create-reminder")
        #expect(harness.commandRuns.map(\.id.rawValue) == ["cmd:schedule.create-reminder"])
        guard case .form = harness.page?.page else {
            Issue.record("Create Reminder did not open its form")
            return
        }
    }

    @Test func listsSeenFeedTheSettingsPicker() async throws {
        let harness = F.harness(F.store(reminders: Self.reminders))
        let signal = try #require(harness.feature.declarationChanges)
        #expect(harness.feature.reminderListChoices.map(\.title) == ["Same as in Reminders"])
        harness.context.settings[ScheduleSettings.defaultReminderList] = F.errands.id
        #expect(
            harness.feature.reminderListChoices.map(\.title) == ["Same as in Reminders", "The list you chose before"])

        try await harness.run("my-reminders")
        #expect(signal.generation == 1)
        #expect(harness.feature.reminderListChoices.map(\.value) == ["", F.inbox.id, F.errands.id])
        try await harness.reloadPage()
        #expect(signal.generation == 1, "the same lists send nothing")
    }
}
