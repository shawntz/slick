import Foundation
import Kit

/// What the feature needs from the user's calendars and reminders. It lives in this package
/// because no other feature needs it.
///
/// Every call that does work is `@concurrent`, so it runs off the main thread whoever calls it. A
/// call throws ``ScheduleError/accessMissing(_:)`` when its permission is missing; it never asks for
/// one. Only the host asks, after the user pressed Grant.
///
/// The live store, ``EventKitStore``, reads and writes the user's real calendars. The isolated one,
/// ``MemoryScheduleStore``, keeps everything in memory, for tests, scenarios and self-tests.
nonisolated protocol ScheduleStore: Sendable {
    /// Fires when events or reminders changed, from this app or another.
    var changes: ChangeSignal { get }

    /// True when the store can read this kind. Never prompts.
    @concurrent func hasAccess(_ kind: CalendarKind) async -> Bool

    /// The calendars that hold events, or the lists that hold reminders.
    @concurrent func calendars(_ kind: CalendarKind) async throws -> [CalendarInfo]

    /// Every occurrence that overlaps `start..<end`, recurring events expanded, in no set order.
    @concurrent func events(from start: Date, to end: Date) async throws -> [EventOccurrence]

    /// Saves a new event and returns it as stored.
    @concurrent func createEvent(_ draft: EventDraft) async throws -> EventOccurrence

    /// Every reminder that is not completed, with or without a due date, in no set order.
    @concurrent func reminders() async throws -> [ReminderItem]

    /// Saves a new reminder and returns it as stored.
    @concurrent func createReminder(_ draft: ReminderDraft) async throws -> ReminderItem

    /// Marks a reminder completed. Throws ``ScheduleError/notFound`` when it is gone.
    @concurrent func complete(reminderID: String) async throws

    /// Deletes a reminder. Throws ``ScheduleError/notFound`` when it is gone.
    @concurrent func delete(reminderID: String) async throws
}

/// The store for each kind of run. Scenarios, self-tests and benchmarks get sample data in memory,
/// so they never read or change the user's calendars.
nonisolated enum ScheduleStoreKey: FeatureServiceKey {
    static func live(_ context: FeatureContext) -> any ScheduleStore {
        EventKitStore()
    }

    static func isolated(_ context: FeatureContext) -> any ScheduleStore {
        MemoryScheduleStore.sample(now: context.clock.now, calendar: context.clock.calendar)
    }
}
