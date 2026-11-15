import Foundation
import Kit

/// What a reminder row carries for its actions, so they work from the row alone.
nonisolated struct ReminderSummary: Codable, Hashable, Sendable {
    var id: String
    var title: String
    var listTitle: String

    init(_ reminder: ReminderItem) {
        id = reminder.id
        title = OneLine.clean(reminder.title, limit: 160)
        listTitle = OneLine.clean(reminder.listTitle, limit: 60)
    }
}

/// Where a reminder stands at a moment.
nonisolated enum ReminderGroup: String, CaseIterable, Sendable {
    case overdue
    case today
    case upcoming
    case undated
}

/// Turns reminders into My Reminders' sections and rows. Pure and `nonisolated`.
nonisolated enum ReminderRows {
    /// The namespace of My Reminders' rows.
    static let namespace = "schedule.reminder"
    /// The filter option that shows every list.
    static let allLists = "all"

    @concurrent static func sections(_ reminders: [ReminderItem], listID: String?, clock: FrozenClock) async
        -> [ListSection]
    {
        build(reminders, listID: listID, clock: clock)
    }

    /// Overdue, Today, Upcoming and No Due Date, in that order, empty ones left out by the host.
    static func build(_ reminders: [ReminderItem], listID: String?, clock: any ClockService) -> [ListSection] {
        var groups: [ReminderGroup: [ReminderItem]] = [:]
        for reminder in reminders where listID == nil || reminder.listID == listID {
            groups[group(of: reminder, clock: clock), default: []].append(reminder)
        }
        let text = TimeText(clock: clock)
        let past = DaySections(clock: clock, direction: .past)
        let future = DaySections(clock: clock, direction: .future)
        return ReminderGroup.allCases.compactMap { group in
            guard let items = groups[group], !items.isEmpty else { return nil }
            let rows = sorted(items, in: group).map { reminder in
                row(for: reminder, group: group, text: text, days: group == .overdue ? past : future)
            }
            return ListSection(Strings.Reminders.section(group), id: group.rawValue, rows: rows)
        }
    }

    /// A timed reminder is overdue once its time passes; one due on a day, once that day is over.
    static func group(of reminder: ReminderItem, clock: any ClockService) -> ReminderGroup {
        guard let due = reminder.due else { return .undated }
        let calendar = clock.calendar
        let now = clock.now
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: due)
        if reminder.dueHasTime ? due < now : day < today { return .overdue }
        return day == today ? .today : .upcoming
    }

    static func sorted(_ reminders: [ReminderItem], in group: ReminderGroup) -> [ReminderItem] {
        reminders.sorted { left, right in
            if group != .undated, let leftDue = left.due, let rightDue = right.due, leftDue != rightDue {
                return leftDue < rightDue
            }
            if left.dueHasTime != right.dueHasTime { return !left.dueHasTime }
            if rank(left.priority) != rank(right.priority) { return rank(left.priority) < rank(right.priority) }
            if left.title != right.title { return left.title < right.title }
            return left.id < right.id
        }
    }

    private static func rank(_ priority: ReminderPriority) -> Int {
        switch priority {
        case .high: 0
        case .medium: 1
        case .low: 2
        case .none: 3
        }
    }

    static func row(for reminder: ReminderItem, group: ReminderGroup, text: TimeText, days: DaySections) -> Row {
        var accessories: [Accessory] = []
        if let mark = Strings.Reminders.priorityMark(reminder.priority) {
            accessories.append(.text(mark, color: .orange))
        }
        let list = OneLine.clean(reminder.listTitle, limit: 40)
        if !list.isEmpty { accessories.append(.tag(list, color: reminder.listColor)) }
        var keywords = [list]
        if let notes = reminder.notes { keywords.append(OneLine.clean(notes, limit: 200)) }
        let title = OneLine.clean(reminder.title)
        return Row(
            id: ItemID(namespace, reminder.id), title: title.isEmpty ? Strings.Reminders.untitled : title,
            subtitle: due(of: reminder, text: text, days: days),
            icon: .symbol(group == .overdue ? "exclamationmark.circle" : "circle", tint: reminder.listColor ?? .gray),
            accessories: accessories, keywords: keywords.filter { !$0.isEmpty },
            payload: Payload(ReminderSummary(reminder)), subtitleColor: group == .overdue ? .red : nil)
    }

    /// "Today at 3:00 PM", "Yesterday", "Monday, November 30 at 9:00 AM", or nil with no due date.
    static func due(of reminder: ReminderItem, text: TimeText, days: DaySections) -> String? {
        guard let due = reminder.due else { return nil }
        let day = days.title(for: due)
        return reminder.dueHasTime ? Strings.Reminders.dueAt(day: day, time: text.time(due)) : day
    }

    /// The list dropdown: every list, then each by name.
    static func dropdown(_ lists: [CalendarInfo]) -> FilterDropdown {
        let sorted = lists.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let options =
            [FilterOption(id: allLists, title: Strings.Reminders.allLists)]
            + sorted.map { FilterOption(id: $0.id, title: OneLine.clean($0.title, limit: 60), icon: listIcon($0)) }
        return FilterDropdown(title: Strings.Reminders.listFilter, options: options, defaultID: allLists)
    }

    static func listIcon(_ list: CalendarInfo) -> Icon {
        .symbol("list.bullet.circle.fill", tint: list.color ?? .gray)
    }
}
