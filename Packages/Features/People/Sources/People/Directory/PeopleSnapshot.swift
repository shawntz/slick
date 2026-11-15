import Foundation
import Kit

/// Everyone the store returned, once each, sorted by name, with the rows the list and root search
/// show. Built off the main thread after each read and never changed afterwards, so the main
/// thread only swaps one reference for another.
nonisolated final class PeopleSnapshot: Sendable {
    /// The row namespace: `contact:<store identifier>`. Root search treats it as a contact.
    static let namespace = "contact"

    /// Sorted by title, case and accents ignored, then by identifier.
    let people: [Person]
    /// Rows for Search Contacts: names plus job, emails and numbers to match.
    let listRows: [Row]
    /// Rows for root search: names, nicknames, organisations and their spellings only.
    let catalogRows: [Row]
    private let positions: [String: Int]

    /// One person's rows, worked out before sorting.
    private struct Entry: Sendable {
        let person: Person
        let key: String
        let catalogRow: Row
        let listRow: Row

        init(_ person: Person, speller: LatinSpeller) {
            let name = PersonName.fullName(of: person)
            let title = PersonName.title(of: person, name: name)
            self.person = person
            key = PersonName.sortKey(title)
            catalogRow = PeopleSnapshot.row(for: person, title: title, name: name, speller: speller)
            var listRow = catalogRow
            listRow.keywords = PersonName.listKeywords(of: person, title: title, rootKeywords: catalogRow.keywords)
            self.listRow = listRow
        }
    }

    private init(sorted entries: [Entry]) {
        people = entries.map(\.person)
        catalogRows = entries.map(\.catalogRow)
        listRows = entries.map(\.listRow)
        var positions: [String: Int] = [:]
        positions.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() { positions[entry.person.id] = index }
        self.positions = positions
    }

    /// Reads the store and builds a snapshot, off the main thread.
    @concurrent static func read(from service: any PeopleService) async throws -> PeopleSnapshot {
        let people = try await service.people()
        try Task.checkCancellation()
        return await build(people)
    }

    /// Builds the snapshot off the main thread. A card the store returned twice is kept once.
    /// Rows are worked out in chunks that run in parallel, then sorted once.
    @concurrent static func build(_ fetched: [Person]) async -> PeopleSnapshot {
        var seen = Set<String>()
        let unique = fetched.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        let chunkSize = max(500, (unique.count + 7) / 8)
        let chunks = stride(from: 0, to: unique.count, by: chunkSize).map {
            Array(unique[$0..<min($0 + chunkSize, unique.count)])
        }
        var parts = [[Entry]](repeating: [], count: chunks.count)
        await withTaskGroup(of: (Int, [Entry]).self) { group in
            for (index, chunk) in chunks.enumerated() {
                group.addTask {
                    let speller = LatinSpeller()
                    return (index, chunk.map { Entry($0, speller: speller) })
                }
            }
            for await (index, part) in group { parts[index] = part }
        }
        let unsorted = parts.flatMap(\.self)
        // Sorting positions moves small values; the folding already set case and accents aside.
        let order = unsorted.indices.sorted { left, right in
            let (a, b) = (unsorted[left], unsorted[right])
            return a.key != b.key ? a.key < b.key : a.person.id < b.person.id
        }
        let entries = order.map { unsorted[$0] }
        return PeopleSnapshot(sorted: entries)
    }

    /// The person with this store identifier.
    func person(id: String) -> Person? {
        positions[id].map { people[$0] }
    }

    /// The root search row for a person: name, what tells them apart, and an icon. Rows are
    /// `.learnOnly`, so root learns from them but never keeps a snapshot of a person.
    static func row(for person: Person, title: String, name: String, speller: LatinSpeller = LatinSpeller()) -> Row {
        let isOrganization = PersonName.titleIsOrganization(person, name: name)
        return Row(
            id: ItemID(namespace, person.id), title: title,
            subtitle: PersonName.subtitle(of: person, title: title, name: name),
            icon: .symbol(isOrganization ? "building.2.crop.circle" : "person.crop.circle"),
            keywords: PersonName.rootKeywords(of: person, title: title, name: name, speller: speller),
            memory: .learnOnly)
    }
}
