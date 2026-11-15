import Foundation
import Kit

/// My Reminders: reminders that are not completed, overdue first, with a dropdown of lists.
final class ReminderList: ListSource {
    private let store: any ScheduleStore
    private let context: FeatureContext
    private let sawLists: @MainActor ([CalendarInfo]) -> Void

    /// - Parameter sawLists: Called with the lists each load read, so settings can offer them.
    init(store: any ScheduleStore, context: FeatureContext, sawLists: @escaping @MainActor ([CalendarInfo]) -> Void) {
        self.store = store
        self.context = context
        self.sawLists = sawLists
    }

    var changes: ChangeSignal? { store.changes }

    /// The page's dropdown before the lists are known. Each load replaces it.
    static let initialFilter = ReminderRows.dropdown([])

    func load(_ request: ListRequest) async throws -> ListResult {
        let clock = FrozenClock(context.clock)
        let reminders: [ReminderItem]
        let lists: [CalendarInfo]
        do {
            reminders = try await store.reminders()
            lists = try await store.calendars(.reminders)
        } catch ScheduleError.accessMissing(let permission) {
            return ListResult(sections: [], emptyState: AccessEmptyState.make(for: permission))
        }
        try Task.checkCancellation()
        sawLists(lists)
        let filter = request.filter.flatMap { $0 == ReminderRows.allLists ? nil : $0 }
        let sections = await ReminderRows.sections(reminders, listID: filter, clock: clock)
        try Task.checkCancellation()
        return ListResult(sections: sections, filter: ReminderRows.dropdown(lists))
    }

    func actions(for row: Row) -> [Action] {
        guard let summary = try? row.payload?.decode(ReminderSummary.self) else { return [] }
        return ReminderActions.actions(for: summary, store: store)
    }

    static let emptyState = EmptyState(
        icon: .symbol("checklist"), title: Strings.Reminders.emptyTitle, message: Strings.Reminders.emptyMessage,
        actions: [
            .runCommand(
                ItemID.command(feature: ScheduleFeature.manifest.id, command: ScheduleFeature.CommandID.createReminder),
                title: Strings.Commands.createReminder, icon: .symbol("plus.circle"))
        ])
}

/// Complete, Open in Reminders and Delete for one reminder.
enum ReminderActions {
    static func actions(for summary: ReminderSummary, store: any ScheduleStore) -> [Action] {
        [complete(summary, store: store), openInReminders(summary), delete(summary, store: store)]
    }

    static func complete(_ summary: ReminderSummary, store: any ScheduleStore) -> Action {
        Action(
            Strings.Reminders.complete, id: "complete", icon: .symbol("checkmark.circle"), requires: [.reminders]
        ) { context in
            do {
                try await store.complete(reminderID: summary.id)
            } catch ScheduleError.accessMissing(let permission) {
                return .needsPermission(permission)
            }
            context.showToast(.success(Strings.Reminders.completed))
            return .keepOpen
        }
    }

    /// Shows the reminder in Reminders, or opens Reminders when the link does not work.
    static func openInReminders(_ summary: ReminderSummary) -> Action {
        Action(
            Strings.Reminders.openInReminders, id: "open-in-reminders", icon: .symbol("checklist"), shortcut: .open
        ) { context in
            if let url = CalendarAppLinks.reminder(id: summary.id), (try? await context.workspace.open(url)) != nil {
                return .close()
            }
            try await context.workspace.launch(bundleID: CalendarAppLinks.remindersBundleID)
            return .close()
        }
    }

    /// Deletes after asking. Deleting removes the reminder on every device the list syncs to.
    static func delete(_ summary: ReminderSummary, store: any ScheduleStore) -> Action {
        Action(
            Strings.Reminders.delete, id: "delete", icon: .symbol("trash"), shortcut: .remove, style: .destructive,
            confirmation: Confirmation(
                Strings.Reminders.deleteQuestion(summary.title), message: Strings.Reminders.deleteMessage,
                confirmTitle: Strings.Reminders.deleteConfirm, isDestructive: true),
            requires: [.reminders]
        ) { context in
            do {
                try await store.delete(reminderID: summary.id)
            } catch ScheduleError.accessMissing(let permission) {
                return .needsPermission(permission)
            }
            context.showToast(.success(Strings.Reminders.deleted))
            return .keepOpen
        }
    }
}
