import Foundation
import Synchronization

/// A contact store in memory, for scenarios, self-tests, benchmarks and tests. It touches nothing
/// on the Mac. Tests fill it with invented people, change it while a page is open, and take
/// access away to see what the feature does.
nonisolated final class InMemoryPeople: PeopleService {
    private struct State {
        var people: [Person]
        var photos: [String: Data]
        var readable = true
        var failure: PeopleError?
        var peopleReads = 0
        var photoReads = 0
        var listeners: [Int: AsyncStream<Void>.Continuation] = [:]
        var nextListener = 0
    }

    private let state: Mutex<State>

    init(people: [Person] = [], photos: [String: Data] = [:]) {
        state = Mutex(State(people: people, photos: photos))
    }

    // MARK: - What tests set and read

    /// False makes every read throw ``PeopleError/accessMissing``, as the live store does when
    /// access was turned off.
    var isReadable: Bool {
        get { state.withLock { $0.readable } }
        set { state.withLock { $0.readable = newValue } }
    }

    /// When set, every read throws it.
    var failure: PeopleError? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }

    /// How many times ``people()`` ran, whether or not it threw.
    var peopleReads: Int { state.withLock { $0.peopleReads } }

    /// How many times ``photo(of:)`` ran.
    var photoReads: Int { state.withLock { $0.photoReads } }

    /// How many ``storeChanges()`` streams are open.
    var listenerCount: Int { state.withLock { $0.listeners.count } }

    /// Replaces every card and tells the listeners, as a sync would.
    func replace(_ people: [Person], photos: [String: Data]? = nil) {
        let listeners = state.withLock { state in
            state.people = people
            if let photos { state.photos = photos }
            return Array(state.listeners.values)
        }
        for listener in listeners { listener.yield() }
    }

    /// Adds or replaces one card and tells the listeners.
    func save(_ person: Person) {
        var people = state.withLock { $0.people }
        if let index = people.firstIndex(where: { $0.id == person.id }) {
            people[index] = person
        } else {
            people.append(person)
        }
        replace(people)
    }

    /// Deletes one card and tells the listeners.
    func delete(id: String) {
        replace(state.withLock { $0.people }.filter { $0.id != id })
    }

    // MARK: - PeopleService

    func people() async throws -> [Person] {
        try state.withLock { state in
            state.peopleReads += 1
            if !state.readable { throw PeopleError.accessMissing }
            if let failure = state.failure { throw failure }
            return state.people
        }
    }

    func photo(of id: String) async throws -> Data? {
        try state.withLock { state in
            state.photoReads += 1
            if !state.readable { throw PeopleError.accessMissing }
            if let failure = state.failure { throw failure }
            return state.photos[id]
        }
    }

    func storeChanges() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = state.withLock { state in
            state.nextListener += 1
            state.listeners[state.nextListener] = continuation
            return state.nextListener
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.listeners.removeValue(forKey: id) }
        }
        return stream
    }
}

extension InMemoryPeople {
    /// The invented people scenarios and self-tests see. Numbers use the 555-01xx range kept for
    /// fiction, and addresses use example.com and made-up streets.
    nonisolated static let sample: [Person] = [
        Person(
            id: "sample-ana", givenName: "Ana", familyName: "Lima", nickname: "Annie", organization: "Example Studio",
            jobTitle: "Designer",
            phones: [LabeledValue("mobile", "+1 (555) 010-0101"), LabeledValue("work", "+1 555 010 0102 ext. 7")],
            emails: [LabeledValue("home", "ana@example.com"), LabeledValue("work", "ana.lima@example.org")],
            addresses: [
                PostalAddress(
                    label: "home", street: "12 Sample Street", city: "Springfield", state: "ST", postalCode: "00001",
                    country: "United States")
            ],
            birthday: Birthday(day: 14, month: 3, year: 1990)),
        Person(
            id: "sample-bruno", givenName: "Bruno", familyName: "Costa",
            phones: [LabeledValue("mobile", "+44 7700 900123")], emails: [LabeledValue("", "bruno@example.net")],
            birthday: Birthday(day: 2, month: 11, year: nil)),
        Person(
            id: "sample-daria", givenName: "Дарья", familyName: "Иванова", organization: "Example Books",
            emails: [LabeledValue("work", "daria@example.com")]),
        Person(
            id: "sample-hiro", givenName: "宏", familyName: "田中", phoneticGivenName: "ひろし",
            phoneticFamilyName: "たなか", phones: [LabeledValue("mobile", "+81 90-0000-0000")]),
        Person(
            id: "sample-wei", givenName: "伟", familyName: "王", emails: [LabeledValue("", "wei@example.cn")]),
        Person(
            id: "sample-bakery", kind: .organization, organization: "Example Bakery",
            phones: [LabeledValue("main", "555-0100")],
            addresses: [
                PostalAddress(
                    label: "work", street: "1 Market Lane", city: "Springfield", postalCode: "00002",
                    country: "United States")
            ]),
        Person(id: "sample-lea", givenName: "Léa", familyName: "Müller", emails: [LabeledValue("", "lea@example.de")]),
    ]
}
