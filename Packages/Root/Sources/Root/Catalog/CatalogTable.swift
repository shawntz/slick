import Foundation
import Kit

/// One item root search can find, with the row it shows.
nonisolated struct CatalogEntry: Sendable {
    /// Where the item came from. When two inputs share an ID, the earlier origin wins.
    enum Origin: Sendable, Equatable {
        /// A feature's command.
        case command
        /// A catalog source, a feature's or a built-in one.
        case source
        /// A row the user ran that came from a live provider or a suggestion.
        case remembered
    }

    /// Built once per catalog change, so a query maps a hit to its row with a lookup.
    var row: Row
    /// The feature that made the row. Nil for built-in sources.
    var featureID: String?
    var origin: Origin
}

/// Every item in the engine's catalog by engine key.
nonisolated struct CatalogTable: Sendable {
    var entries: [UInt64: CatalogEntry] = [:]
    /// The soonest moment a row expires. Root rebuilds the catalog then.
    var earliestExpiry: Date?

    var count: Int { entries.count }

    subscript(key: UInt64) -> CatalogEntry? {
        entries[key]
    }

    /// The entry for an ID, when its key does not belong to another ID.
    func entry(for id: ItemID) -> CatalogEntry? {
        guard let entry = entries[id.engineKey], entry.row.id == id else { return nil }
        return entry
    }
}
