import Foundation
import Kit

/// The Search Contacts list: everyone in one section, sorted by name, filtered by the host. Rows
/// match on names, nicknames, companies, jobs, email addresses and phone numbers.
///
/// The rows are built off the main thread when the directory reads the store, so opening the list
/// hands the host rows it already has.
@MainActor final class PeopleList: ListSource {
    private let directory: PeopleDirectory
    private let builder: PeopleActions
    private let locale: Locale
    /// Called when a load finds access missing, so the feature can wait for a grant.
    var onAccessMissing: (() -> Void)?

    init(directory: PeopleDirectory, actions: PeopleActions, locale: Locale) {
        self.directory = directory
        self.builder = actions
        self.locale = locale
    }

    var changes: ChangeSignal? { directory.changes }

    /// The page as the Search Contacts command pushes it.
    func page(initialQuery: String = "") -> ListPage {
        ListPage(
            self, searchPlaceholder: Strings.Commands.searchPlaceholder, showsDetail: true,
            emptyState: EmptyState(
                icon: .symbol("person.crop.circle.badge.questionmark"), title: Strings.List.noMatchesTitle),
            initialQuery: initialQuery)
    }

    func load(_ request: ListRequest) async throws -> ListResult {
        let snapshot: PeopleSnapshot
        do {
            snapshot = try await directory.current()
        } catch PeopleError.accessMissing {
            onAccessMissing?()
            return ListResult(rows: [], emptyState: accessEmptyState)
        }
        guard !snapshot.people.isEmpty else {
            return ListResult(
                rows: [],
                emptyState: EmptyState(
                    icon: .symbol("person.crop.circle"), title: Strings.List.emptyTitle,
                    message: Strings.List.emptyMessage))
        }
        return ListResult(sections: [ListSection(id: "people", rows: snapshot.listRows)])
    }

    func actions(for row: Row) -> [Action] {
        builder.actions(for: row)
    }

    func detail(for row: Row) async throws -> Detail? {
        guard let person = directory.person(id: row.id.key) else { return nil }
        let photo = await directory.thumbnail(for: person)
        try Task.checkCancellation()
        return PersonDetail.make(person, photo: photo, locale: locale)
    }

    /// What the list shows while access is off: why, and a button that asks for it. The host shows
    /// the manifest's reason and asks macOS only when the user presses it.
    private var accessEmptyState: EmptyState {
        let directory = directory
        return EmptyState(
            icon: .symbol("lock"), title: Strings.Access.offTitle, message: Strings.Access.offMessage,
            actions: [
                Action(Strings.Access.allow, id: "allow-access", icon: .symbol("lock.open"), requires: [.contacts]) {
                    context in
                    directory.announcesNextRead = true
                    context.reload()
                    return .keepOpen
                }
            ])
    }
}
