import Foundation
import Kit

/// Settings of the example library feature.
nonisolated enum LibrarySettings {
    static let sortByAuthor = SettingKey("sortByAuthor", default: false)
}

/// A feature with every root search input: commands, a catalog source that changes, instant
/// providers that claim the top or show in their own section, and an async provider.
final class LibraryFeature: Feature {
    static let manifest = FeatureManifest(id: "library", name: "Library", icon: .symbol("books.vertical"))

    let books = BookCatalog()
    let notes = NoteAnswers()
    let counter = CountAnswers()
    let files = FileSearch()

    init(context: FeatureContext) {}

    var commands: [Command] {
        [
            Command(id: "open", title: "Open Library") { _ in .close() },
            Command(
                id: "search", title: "Search Library",
                fallback: Fallback(startsOn: true) { "Search Library for \"\($0)\"" }
            ) { _ in .close() },
            Command(id: "hidden", title: "Hidden Maintenance", showsInRoot: false, allowsDeepLinks: false) { _ in
                .close()
            },
        ]
    }

    var catalogSources: [any CatalogSource] { [books] }
    var liveProviders: [LiveProvider] { [.instant(counter), .instant(notes), .instant(books), .async(files)] }
}

/// Books in root search's catalog. A test changes ``rows`` and sends ``changes``, or sets
/// ``failure`` so the next load throws.
final class BookCatalog: CatalogSource, InstantProvider {
    let namespace = "book"
    let signal = ChangeSignal()
    var rows: [Row] = [
        Row(id: ItemID("book", "1"), title: "Example Book", subtitle: "Shelf A"),
        Row(id: ItemID("book", "2"), title: "Garden Atlas", subtitle: "Shelf B"),
    ]
    var failure: (any Error)?
    private(set) var loads = 0

    var changes: ChangeSignal? { signal }
    var reloadsOnSettings: [AnySettingKey] { [LibrarySettings.sortByAuthor.erased] }

    func rows() async throws -> [Row] {
        loads += 1
        if let failure { throw failure }
        return rows
    }

    /// As an instant provider in the same namespace, it answers a book's full title with the same
    /// row the catalog holds, so root search must show it once.
    func answer(for query: String) -> InstantAnswer? {
        let matches = rows.filter { $0.title.lowercased() == query.lowercased() }
        return matches.isEmpty ? nil : InstantAnswer(rows: matches, sectionTitle: "On the Shelf")
    }

    func actions(for row: Row) -> [Action] {
        [Action("Open Book") { _ in .close() }]
    }
}

/// Notes that exist only as answers: "note <name>" gives one row, which root search remembers when
/// the user runs it. A test deletes a note by adding its ID to ``deleted``.
final class NoteAnswers: InstantProvider, RememberedRowValidator {
    let namespace = "note"
    var memory: RowMemory = .remember
    var deleted: Set<ItemID> = []
    private(set) var checked: [[ItemID]] = []

    func existingItems(among ids: [ItemID]) async -> Set<ItemID> {
        checked.append(ids)
        return Set(ids).subtracting(deleted)
    }

    func answer(for query: String) -> InstantAnswer? {
        guard query.hasPrefix("note "), query.count > 5 else { return nil }
        let name = String(query.dropFirst(5))
        let row = Row(
            id: ItemID("note", name.lowercased()), title: name.capitalized + " List", subtitle: "Note",
            payload: Payload(name), memory: memory)
        return InstantAnswer(rows: [row], sectionTitle: "Notes")
    }

    func actions(for row: Row) -> [Action] {
        [Action("Open Note") { _ in .close() }]
    }
}

/// A calculator-like answer that claims the top for "=<number>" and is never remembered.
final class CountAnswers: InstantProvider {
    let namespace = "count"

    func answer(for query: String) -> InstantAnswer? {
        guard query.hasPrefix("="), let value = Int(query.dropFirst()) else { return nil }
        let row = Row(id: ItemID("count", String(value)), title: "\(value * 2)", memory: .never)
        return InstantAnswer(rows: [row], claimsTop: true)
    }

    func actions(for row: Row) -> [Action] {
        [Action("Copy Answer") { _ in .close() }]
    }
}

/// An async provider: never run by the synchronous path, which only plans its section.
final class FileSearch: AsyncProvider {
    let namespace = "file"
    let sectionTitle = "Files"

    func takesOver(_ query: String) -> Bool {
        query.hasPrefix("/")
    }

    func results(for query: String) async throws -> [Row] {
        []
    }

    func actions(for row: Row) -> [Action] {
        [Action("Reveal") { _ in .close() }]
    }
}

/// A second feature, off until a test turns it on.
final class GardenFeature: Feature {
    static let manifest = FeatureManifest(
        id: "garden", name: "Garden", icon: .symbol("leaf"), isEnabledByDefault: false)

    init(context: FeatureContext) {}

    var commands: [Command] {
        [Command(id: "water", title: "Water Plants") { _ in .close() }]
    }
}

/// Applications, as App's built-in source would list them, in the reserved `app` namespace.
final class ExampleApps: CatalogSource {
    let namespace = ItemID.ReservedNamespace.app
    var rows: [Row]

    init(titles: [String] = ["Terminal", "Term", "Calendar", "Editor", "Preview", "Music"]) {
        rows = titles.map { title in
            Row(id: ItemID(ItemID.ReservedNamespace.app, "com.example." + title.lowercased()), title: title)
        }
    }

    func rows() async throws -> [Row] {
        rows
    }

    func actions(for row: Row) -> [Action] {
        [Action("Open App") { _ in .close() }]
    }

    func id(_ title: String) -> ItemID {
        ItemID(ItemID.ReservedNamespace.app, "com.example." + title.lowercased())
    }
}

/// A catalog source with many rows that share a word, for highlight tests.
final class NumberedItems: CatalogSource {
    let namespace = "numbered"
    let count: Int

    init(count: Int) {
        self.count = count
    }

    func rows() async throws -> [Row] {
        (1...count).map { Row(id: ItemID("numbered", String($0)), title: "Sample Item \($0)") }
    }

    func actions(for row: Row) -> [Action] { [] }
}

struct ExampleFailure: Error {}
