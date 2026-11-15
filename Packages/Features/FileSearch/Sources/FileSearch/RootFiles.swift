import CoreBridge
import Foundation
import Kit

/// Files in root search: a Files section for queries of two characters or more, and a folder
/// listing that takes over for a query starting with "/" or "~". Folder rows complete on Tab, so
/// the user walks down a path by typing and pressing Tab.
///
/// Everything a keystroke reaches on the main thread here is a field read and an `await`: the
/// search, the paths, the highlights and the rows are made on the root search lane.
final class RootFiles: AsyncProvider, RememberedRowValidator {
    let namespace = FileRows.namespace
    let sectionTitle = Strings.Root.section
    let maximumRows = 5

    private let controller: IndexController
    private let lane: SearchLane
    private let fileActions: FileActions

    init(controller: IndexController, lane: SearchLane, actions: FileActions) {
        self.controller = controller
        self.lane = lane
        fileActions = actions
    }

    func takesOver(_ query: String) -> Bool {
        SearchLane.isBrowse(query)
    }

    func sectionTitle(for query: String) -> String {
        SearchLane.isBrowse(query) ? FileRows.folderTitle(for: query) : sectionTitle
    }

    /// A folder listing is cheap and the user expects it at once; a name search waits for typing
    /// to pause.
    func debounce(for query: String) -> Duration {
        SearchLane.isBrowse(query) ? .zero : debounce
    }

    func results(for query: String) async throws -> [Row] {
        guard let index = controller.index, let plan = controller.plan else { return [] }
        let request = SearchRequest(
            query: query, limit: SearchLane.isBrowse(query) ? .max : maximumRows, kind: nil,
            includesHidden: plan.configuration.includeHidden, patterns: plan.patterns,
            style: FileRows.Style(home: plan.home))
        return try await lane.search(request, in: index).rows
    }

    func actions(for row: Row) -> [Action] {
        fileActions.actions(for: row)
    }

    /// Remembered files the index no longer holds are forgotten, and so are files in folders the
    /// user excluded or a protected place no longer searched. Files outside every root, such as on
    /// a volume that is not mounted now, are kept. Answers from the index, never from the disk.
    func existingItems(among ids: [ItemID]) async -> Set<ItemID> {
        guard let index = controller.index, let plan = controller.plan else { return Set(ids) }
        return await Self.existing(ids, in: index, plan: plan)
    }

    @concurrent private static func existing(_ ids: [ItemID], in index: FileIndex, plan: ScopePlan) async -> Set<ItemID>
    {
        guard let snapshot = try? index.snapshot() else { return Set(ids) }
        var kept = Set<ItemID>()
        for id in ids {
            let path = id.key
            if plan.blocked.contains(where: { Paths.isInside(path, $0) }) { continue }
            let inside = plan.roots.contains { Paths.isInside(path, $0) }
            if !inside || snapshot.lookup(path: path) != nil { kept.insert(id) }
        }
        return kept
    }
}
