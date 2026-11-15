import AppKit
import Foundation
import Host
import Kit
import KitHosting
import LauncherUI

/// The host's budgets measured inside an app, as docs/ARCHITECTURE.md asks: main-thread CPU, with
/// a root source that returns 50 rows from a 10,000-row list. ``HostBench`` does the measuring, as
/// it does for App's `--bench`.
@MainActor enum BenchMode {
    static func run(only: String?) async -> Bool {
        let world = await DemoWorld(root: BenchRoot())
        defer { world.panel.surface.panel.close() }
        let bench = HostBench(panel: world.panel)
        let names = only.map { Set($0.split(separator: ",").map(String.init)) }
        return await bench.run(names)
    }
}

/// 10,000 synthetic rows; each query answers 50 of them at almost no cost.
@MainActor final class BenchRoot: RootSource {
    let changes = ChangeSignal()
    let catalog: [Row]
    private(set) var snapshot = RootSnapshot()
    private let empty: RootSnapshot
    private var revision = 1

    init() {
        let symbols = ["map", "envelope", "terminal", "note.text", "calendar", "music.note", "camera", "globe"]
        catalog = (0..<10_000).map { index in
            let symbol = symbols[index % symbols.count]
            return Row(
                id: ItemID("bench", String(index)), title: "Sample Item \(index)",
                subtitle: index.isMultiple(of: 2) ? "Application" : "Document", icon: .symbol(symbol),
                accessories: index.isMultiple(of: 5) ? [.text("\(index % 97)"), .tag("New", color: .green)] : [],
                represents: index.isMultiple(of: 3) ? .text("sample \(index)") : nil)
        }
        empty = RootSnapshot(
            sections: [
                RootSection(id: "suggested", title: "Suggested", rows: Array(catalog.prefix(9)), kind: .suggested)
            ], revision: 1)
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
        for index in 0..<12 { rows[index].titleHighlights = [0..<min(query.utf16.count, 6)] }
        snapshot = RootSnapshot(
            query: query, sections: [RootSection(id: "results", title: "Results", rows: rows, kind: .results)],
            revision: revision)
        return snapshot
    }

    func end() {}
    func titleHighlights(for row: Row) -> [Range<Int>] { [] }
    func featureID(for row: Row) -> String? { nil }
    func row(for id: ItemID) -> Row? { nil }
    func didRun(_ row: Row, launch: LaunchSource) {}
    func forget(_ id: ItemID) {}
    func actions(for row: Row) -> [Action] { DemoRows.actions(for: row) }
}
