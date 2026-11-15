import Foundation
import Kit

/// A catalog of invented items for the bench: app-like names, documents, folders and commands made
/// from word lists by a fixed generator, so every run measures the same catalog. Some titles hold
/// "sample" and "item", the words the host bench types.
@MainActor final class SyntheticCatalog: CatalogSource {
    nonisolated static let benchNamespace = "bench"

    let namespace = SyntheticCatalog.benchNamespace
    let count: Int

    init(count: Int) {
        self.count = count
    }

    func rows() async throws -> [Row] {
        Self.titles(count: count).enumerated().map { index, title in
            Row(
                id: ItemID(Self.benchNamespace, String(index)), title: title,
                subtitle: Self.kinds[index % Self.kinds.count],
                icon: .symbol(Self.symbols[index % Self.symbols.count]), memory: .learnOnly)
        }
    }

    func actions(for row: Row) -> [Action] {
        [Action("Open", id: "open") { _ in .close() }]
    }

    private static let kinds = ["Application", "Document", "Folder", "Command", "Bookmark"]
    private static let symbols = ["app", "doc.text", "folder", "command", "bookmark"]
    nonisolated private static let first = [
        "Sample", "Photo", "Note", "Code", "Music", "Mail", "Calendar", "Terminal", "Studio", "Ledger", "Atlas",
        "Pixel", "Harbor", "Summit", "Signal", "Canvas", "Notebook", "Archive", "Garden", "Orbit", "Prism", "Relay",
        "Quartz", "Tidal", "Vector", "Willow", "Zephyr", "Item", "Report", "Budget",
    ]
    nonisolated private static let second = [
        "Editor", "Viewer", "Studio", "Manager", "Item", "Notes", "Board", "Tracker", "Player", "Reader", "Sync",
        "Lab", "Desk", "Builder", "Monitor", "Planner", "Library", "Inbox", "Sheet", "Draft", "Sketch", "Index",
    ]
    nonisolated private static let suffixes = [
        "", "", "", " Pro", " 2", " Lite", ".txt", ".pdf", " Folder", " Archive",
    ]

    /// The titles, the same for every run with the same count.
    nonisolated static func titles(count: Int) -> [String] {
        var state: UInt64 = 0x5EED_CA7A_1060_0001
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(truncatingIfNeeded: state >> 33)
        }
        return (0..<count).map { index in
            let a = first[next() % first.count]
            let b = second[next() % second.count]
            let suffix = suffixes[next() % suffixes.count]
            return "\(a) \(b)\(suffix) \(index)"
        }
    }
}
