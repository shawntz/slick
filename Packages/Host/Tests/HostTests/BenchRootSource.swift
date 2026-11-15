import Foundation
import Kit
import KitHosting

/// Root search over 10,000 synthetic rows that answers each query with 50 of them, at almost no
/// cost of its own, so a budget measures the host and LauncherUI rather than a matcher.
@MainActor final class BenchRootSource: RootSource {
    static let symbols = [
        "app", "doc", "folder", "terminal", "globe", "star", "bolt", "gear", "music.note", "photo", "calendar",
        "clock", "envelope", "paperplane", "person", "map", "cart", "book", "film", "tray",
    ]

    let changes = ChangeSignal()
    let catalog: [Row]
    private(set) var snapshot = RootSnapshot()
    private let empty: RootSnapshot
    private var revision = 0

    init(count: Int = 10_000) {
        var rows: [Row] = []
        rows.reserveCapacity(count)
        for index in 0..<count {
            let symbol = Self.symbols[index % Self.symbols.count]
            var accessories: [Accessory] = []
            if index % 5 == 0 { accessories = [.text("\(index % 97)"), .tag("New", color: .green)] }
            rows.append(
                Row(
                    id: ItemID("bench", String(index)), title: "Sample Item \(index) \(symbol.capitalized)",
                    subtitle: index % 2 == 0 ? "Application" : "Document", icon: .symbol(symbol),
                    accessories: accessories, represents: index % 3 == 0 ? .text("sample \(index)") : nil))
        }
        catalog = rows
        empty = RootSnapshot(
            sections: [RootSection(id: "suggested", title: "Suggested", rows: Array(rows.prefix(9)), kind: .suggested)],
            revision: 1)
        snapshot = empty
    }

    func begin() -> RootSnapshot {
        snapshot = empty
        return empty
    }

    func update(query: String) -> RootSnapshot {
        guard !query.isEmpty else { return begin() }
        revision += 1
        var start = 0
        for scalar in query.unicodeScalars { start = (start &* 31 &+ Int(scalar.value)) % (catalog.count - 50) }
        var rows = Array(catalog[start..<(start + 50)])
        let length = min(query.utf16.count, 6)
        for index in 0..<12 { rows[index].titleHighlights = [0..<length] }
        snapshot = RootSnapshot(
            query: query, sections: [RootSection(id: "results", title: "Results", rows: rows, kind: .results)],
            completion: nil, revision: revision + 1)
        return snapshot
    }

    func end() {}
    func titleHighlights(for row: Row) -> [Range<Int>] { [] }
    func featureID(for row: Row) -> String? { nil }
    func row(for id: ItemID) -> Row? { nil }
    func didRun(_ row: Row, launch: LaunchSource) {}
    func forget(_ id: ItemID) {}

    func actions(for row: Row) -> [Action] {
        [
            Action("Open", id: "open") { _ in .close() },
            Action("Show in Finder", id: "reveal", shortcut: .reveal) { _ in .keepOpen },
            Action("Copy Name", id: "copy", shortcut: .copy) { _ in .keepOpen },
            Action("Get Info", id: "info") { _ in .keepOpen },
            Action("Move to Trash", id: "trash", style: .destructive) { _ in .keepOpen },
        ]
    }
}
