import Foundation
import Kit
import Synchronization

/// What a row carries so its actions need nothing else: the item, and the Option alternate's.
nonisolated struct MenuRowPayload: Codable, Hashable, Sendable {
    var item: MenuItemRef
    var title: String
    var appName: String
    var isEnabled: Bool
    var optionAlternate: Alternate?

    /// The item that takes this one's place while Option is held.
    struct Alternate: Codable, Hashable, Sendable {
        var item: MenuItemRef
        var title: String
        var isEnabled: Bool
    }
}

/// One page of rows for a list request.
nonisolated struct MenuPage: Sendable {
    var sections: [ListSection]
    /// Where the next page starts, when there is one.
    var nextOffset: Int?
    /// How many items matched in all, across pages.
    var total: Int
}

/// Builds rows from a snapshot. Plain values, so any thread can do it; the list awaits ``page(_:)``
/// so neither searching nor building rows runs on the main thread.
nonisolated enum MenuRows {
    static let namespace = "menu-items"
    /// Rows per page. The host loads the next page as the user scrolls near the end.
    static let pageSize = 200

    /// What one page needs.
    struct Request: Sendable {
        var snapshot: MenuSnapshot
        /// Built from ``entries(_:)``. Needed only when the query is not empty.
        var index: (any FuzzyIndex)?
        var query: String
        var options: MenuOptions
        var offset: Int
    }

    /// Searches, filters and builds one page, off the main thread.
    @concurrent static func page(_ request: Request) async -> MenuPage {
        noteThread()
        return build(request)
    }

    private static func noteThread() {
        if pthread_main_np() != 0 { searchesOnMainThread.add(1, ordering: .relaxed) }
    }

    /// How many searches ran on the main thread. Stays zero; the tests check it.
    static let searchesOnMainThread = Atomic<Int>(0)

    /// The work of ``page(_:)``, on whatever thread calls it.
    static func build(_ request: Request) -> MenuPage {
        let snapshot = request.snapshot
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            let shown = snapshot.items.indices.filter { request.options.shows(snapshot.items[$0]) }
            let slice = window(of: shown.count, from: request.offset)
            var sections: [ListSection] = []
            for position in shown[slice] {
                let item = snapshot.items[position]
                let place = item.path.first?.index ?? 0
                let row = row(item, in: snapshot, highlights: [])
                let id = "menu-\(place)"
                if sections.last?.id == id {
                    sections[sections.count - 1].rows.append(row)
                } else {
                    let title = snapshot.menuTitles[place] ?? item.path.first?.title
                    sections.append(ListSection(title, id: id, rows: [row]))
                }
            }
            return MenuPage(sections: sections, nextOffset: next(after: slice, total: shown.count), total: shown.count)
        }
        guard let index = request.index else { return MenuPage(sections: [], nextOffset: nil, total: 0) }
        let matches = index.search(query, limit: Int.max).filter {
            snapshot.items.indices.contains($0.index) && request.options.shows(snapshot.items[$0.index])
        }
        let slice = window(of: matches.count, from: request.offset)
        let rows = matches[slice].map { row(snapshot.items[$0.index], in: snapshot, highlights: $0.highlights) }
        let sections = rows.isEmpty ? [] : [ListSection(nil, id: "results", rows: rows)]
        return MenuPage(sections: sections, nextOffset: next(after: slice, total: matches.count), total: matches.count)
    }

    /// What the search index holds for each item: its title, and its whole path as one keyword so
    /// "export png" finds PNG under File › Export.
    static func entries(_ snapshot: MenuSnapshot) -> [FuzzyEntry] {
        snapshot.items.map { item in
            let menus = item.menus
            return FuzzyEntry(
                title: item.title, keywords: menus.isEmpty ? [] : [(menus + [item.title]).joined(separator: " ")])
        }
    }

    /// One row. Rows hold other apps' titles, such as recent documents, so root search keeps nothing.
    static func row(_ item: MenuItem, in snapshot: MenuSnapshot, highlights: [Range<Int>]) -> Row {
        let ref = item.ref(bundleID: snapshot.app.bundleID, processID: snapshot.processID)
        var accessories: [Accessory] = []
        if !item.mark.isEmpty {
            let mixed = item.mark == "-" || item.mark == "–"
            accessories.append(
                .icon(
                    .symbol(mixed ? "minus" : "checkmark"),
                    tooltip: mixed ? Strings.mixedTooltip : Strings.checkedTooltip))
        }
        if !item.isEnabled { accessories.append(.tag(Strings.unavailableTag)) }
        if let shortcut = item.shortcut { accessories.append(.shortcut(shortcut)) }
        let alternate = item.optionAlternate.flatMap { snapshot.items.indices.contains($0) ? snapshot.items[$0] : nil }
        let payload = MenuRowPayload(
            item: ref, title: item.title, appName: snapshot.app.name, isEnabled: item.isEnabled,
            optionAlternate: alternate.map {
                MenuRowPayload.Alternate(
                    item: $0.ref(bundleID: snapshot.app.bundleID, processID: snapshot.processID), title: $0.title,
                    isEnabled: $0.isEnabled)
            })
        return Row(
            id: ItemID(namespace, ref.key), title: item.title, subtitle: Strings.path(item.menus),
            icon: .app(bundleID: snapshot.app.bundleID), accessories: accessories, payload: Payload(payload),
            alternates: alternate.map {
                [Row.Alternate(modifiers: .option, subtitle: Strings.optionSubtitle($0.title))]
            }
                ?? [],
            titleHighlights: highlights, memory: .never)
    }

    private static func window(of count: Int, from offset: Int) -> Range<Int> {
        let start = min(max(0, offset), count)
        return start..<min(count, start + pageSize)
    }

    private static func next(after slice: Range<Int>, total: Int) -> Int? {
        slice.upperBound < total ? slice.upperBound : nil
    }
}
