import CoreBridge
import Foundation
import Kit
import KitHosting

/// What the catalog is built from, copied off the main actor.
nonisolated struct CatalogInputs: Sendable {
    /// A command that shows in root search, with its feature's name and icon for the row.
    struct CommandInput: Sendable {
        var entry: CommandEntry
        var featureName: String
        var featureIcon: Icon
    }

    /// One catalog source's rows as last loaded.
    struct SourceInput: Sendable {
        var featureID: String?
        var rows: [Row]
    }

    /// The feature that owns a namespace. Nil for a built-in source.
    struct Owner: Sendable {
        var featureID: String?
    }

    var commands: [CommandInput] = []
    var sources: [SourceInput] = []
    /// Remembered rows with their feature, in no particular order.
    var remembered: [(row: Row, featureID: String?)] = []
    /// Where the builder reads the rest of the remembered rows, on the engine queue, so the main
    /// thread never copies them.
    var memory: ItemMemory?
    /// The namespaces a source that is on owns. A remembered row joins only while its namespace is
    /// owned.
    var owners: [String: Owner] = [:]
}

/// Builds the engine's items and the matching row table from the catalog inputs. Pure, and slow
/// enough at 10,000 items that it runs on the engine queue.
nonisolated enum CatalogBuilder {
    /// The engine source that holds the whole catalog. One source, replaced as a whole, keeps each
    /// key in exactly one place: the engine moves a key between sources, which would lose it when
    /// one of two sources that share it drops it.
    static let engineSource: UInt32 = 1

    /// The table and the engine items. Commands win over catalog sources, which win over remembered
    /// rows. Rows that expired at `now` are left out.
    static func build(_ inputs: CatalogInputs, now: Date) -> (table: CatalogTable, items: [CatalogItem]) {
        var table = CatalogTable()
        var items: [CatalogItem] = []
        let capacity = inputs.commands.count + inputs.sources.reduce(0) { $0 + $1.rows.count } + inputs.remembered.count
        table.entries.reserveCapacity(capacity)
        items.reserveCapacity(capacity)

        func add(_ row: Row, featureID: String?, origin: CatalogEntry.Origin) {
            if let expires = row.expires {
                guard expires > now else { return }
                table.earliestExpiry = min(table.earliestExpiry ?? expires, expires)
            }
            let key = row.id.engineKey
            guard table.entries[key] == nil else { return }
            var stored = row
            stored.titleHighlights = []
            table.entries[key] = CatalogEntry(row: stored, featureID: featureID, origin: origin)
            items.append(item(for: stored))
        }

        for command in inputs.commands {
            add(commandRow(command), featureID: command.entry.featureID, origin: .command)
        }
        for source in inputs.sources {
            for row in source.rows {
                add(row, featureID: source.featureID, origin: .source)
            }
        }
        for remembered in inputs.remembered {
            add(remembered.row, featureID: remembered.featureID, origin: .remembered)
        }
        for row in inputs.memory?.rememberedRows() ?? [] {
            guard let owner = inputs.owners[row.id.namespace] else { continue }
            add(row, featureID: owner.featureID, origin: .remembered)
        }
        return (table, items)
    }

    /// The row a command shows in root search. The subtitle names the feature unless the command
    /// has its own.
    static func commandRow(_ input: CatalogInputs.CommandInput) -> Row {
        let command = input.entry.command
        return Row(
            id: input.entry.id, title: command.title, subtitle: command.subtitle ?? input.featureName,
            icon: command.icon ?? input.featureIcon, keywords: command.keywords)
    }

    /// The engine item for a row. A row that root search must never learn from is also never
    /// suggested.
    static func item(for row: Row) -> CatalogItem {
        CatalogItem(
            key: ItemKey(rawValue: row.id.engineKey),
            title: clean(row.title),
            keywords: row.keywords.compactMap { keyword in
                let cleaned = clean(keyword)
                return cleaned.isEmpty ? nil : cleaned
            },
            kind: ItemKinds.kind(of: row),
            flags: row.memory == .never ? [.noLearn, .noSuggest] : [])
    }

    /// The text without the unit separator, which the engine uses between keywords. A keyword that
    /// held one would make the engine refuse the whole catalog.
    static func clean(_ text: String) -> String {
        guard text.utf8.contains(separator) else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value != UInt32(separator) }))
    }

    private static let separator: UInt8 = 0x1F
}
