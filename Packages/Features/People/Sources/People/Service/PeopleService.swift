import Foundation
import Kit

/// The contact store, as the feature reads it. It lives in this package because no other feature
/// needs it.
///
/// The live service wraps `CNContactStore`: it reads the user's contacts, so it runs only in the
/// app, and only after macOS says the app may read them. The isolated one is an in-memory store
/// that scenarios and tests fill with invented people.
///
/// Every requirement that does work is `@concurrent`, so it runs off the main thread whoever calls
/// it. No requirement asks for access: the host does that, from the user's own action.
nonisolated protocol PeopleService: Sendable {
    /// Every card, unified across accounts as Contacts shows them, with only the fields the
    /// feature shows and no photos. Throws ``PeopleError/accessMissing`` without reading anything
    /// when macOS does not let the app read contacts, so it never raises a prompt.
    @concurrent func people() async throws -> [Person]

    /// The card's photo as stored, usually a small JPEG or PNG. Nil when it has none or is gone.
    /// Throws ``PeopleError/accessMissing`` as ``people()`` does.
    @concurrent func photo(of id: String) async throws -> Data?

    /// Yields once each time the store changes, such as when the user edits a card in Contacts or
    /// an account syncs. Asking for it reads no contacts. It ends when the consuming task is
    /// cancelled.
    func storeChanges() -> AsyncStream<Void>
}

/// Why the contact store did not answer.
nonisolated enum PeopleError: Error, Hashable, Sendable, LocalizedError {
    /// macOS does not let the app read contacts: never asked, turned off, or blocked by a profile.
    case accessMissing
    /// The store failed for another reason.
    case unreadable

    var errorDescription: String? {
        switch self {
        case .accessMissing: Strings.Access.offTitle
        case .unreadable: Strings.Failures.unreadable
        }
    }

    var failureReason: String? {
        switch self {
        case .accessMissing: Strings.Access.offMessage
        case .unreadable: Strings.Failures.unreadableMessage
        }
    }
}

/// The contact store for each kind of run.
nonisolated enum PeopleServiceKey: FeatureServiceKey {
    static func live(_ context: FeatureContext) -> any PeopleService {
        LiveContacts()
    }

    static func isolated(_ context: FeatureContext) -> any PeopleService {
        InMemoryPeople(people: InMemoryPeople.sample)
    }
}
