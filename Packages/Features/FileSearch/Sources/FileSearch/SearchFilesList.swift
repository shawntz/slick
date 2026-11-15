import CoreBridge
import Foundation
import Kit

/// The Search Files page: the files and folders the user ran most recently while the query is
/// empty, name search and folder listings as they type, a dropdown that filters by kind, and a
/// preview with the selected item's size, dates and kind.
///
/// The source filters by itself, on the page's own search lane, because the index lives in the
/// Rust core. Rows carry their highlights. The page reloads when the index's state changes, such
/// as when a walk ends or a protected folder joins, not on every batch of file events, so rows do
/// not move under the user while a busy folder changes.
final class SearchFilesList: ListSource {
    /// The most rows one search shows.
    static let rowLimit = 100
    /// The most recent items shown while the query is empty.
    static let recentLimit = 30

    private unowned let feature: FileSearchFeature

    init(feature: FileSearchFeature) {
        self.feature = feature
    }

    var filtering: ListFiltering { .custom(debounce: .milliseconds(50)) }

    var changes: ChangeSignal? { feature.controller.stateChanges }

    static var dropdown: FilterDropdown {
        FilterDropdown(
            title: Strings.Page.kindFilter,
            options: [FilterOption(id: FileKind.allID, title: Strings.Kinds.all)]
                + FileKind.allCases.map { FilterOption(id: $0.rawValue, title: Strings.Kinds.title($0)) },
            defaultID: FileKind.allID)
    }

    func load(_ request: ListRequest) async throws -> ListResult {
        if request.reason == .open { feature.recheckAccess() }
        let notice = feature.notice()
        let controller = feature.controller
        guard let index = controller.index, let plan = controller.plan else {
            let failed = controller.summary.phase == .failed
            return ListResult(
                rows: [], emptyState: failed ? Strings.Page.failedState : Strings.Page.buildingState, notice: notice)
        }
        let kind = request.filter.flatMap(FileKind.init(rawValue:))
        let style = FileRows.Style(home: plan.home, showsDate: true)
        let query = request.query.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            let paths = feature.context.usage.recentlyUsed(namespace: FileRows.namespace, limit: Self.recentLimit)
                .map(\.id.key).filter(plan.allows)
            let rows = try await feature.pageLane.recents(paths, in: index, kind: kind, style: style)
            try Task.checkCancellation()
            return ListResult(
                sections: [ListSection(Strings.Page.recentSection, id: "recent", rows: rows)],
                emptyState: Strings.Page.noRecentsState, notice: notice)
        }
        let search = SearchRequest(
            query: request.query, limit: Self.rowLimit, kind: kind, includesHidden: plan.configuration.includeHidden,
            patterns: plan.patterns, style: style)
        let result = try await feature.pageLane.search(search, in: index)
        try Task.checkCancellation()
        let browsing = SearchLane.isBrowse(request.query)
        return ListResult(
            sections: [
                ListSection(browsing ? FileRows.folderTitle(for: request.query) : nil, id: "results", rows: result.rows)
            ],
            emptyState: result.notIndexed ? Strings.Page.notIndexedState : Strings.Page.noMatchesState, notice: notice)
    }

    /// A preview, and what the index and the item's own metadata say about it. Only the selected
    /// row's facts are read, off the main thread, and only for a path the scope allows.
    func detail(for row: Row) async throws -> Detail? {
        guard row.id.namespace == FileRows.namespace else { return nil }
        let controller = feature.controller
        let path = row.id.key
        guard let index = controller.index, let plan = controller.plan, plan.allows(path) else { return nil }
        let entry = await Self.entry(at: path, in: index)
        try Task.checkCancellation()
        let facts = await feature.fileSystem.facts(of: path) ?? FileFacts()
        try Task.checkCancellation()
        let item = FileRows.item(of: row)
        let name = Paths.name(of: path)
        let flags = entry?.flags ?? []
        var metadata: [MetadataItem] = []
        let kind = facts.kind ?? FileKind.of(name: name, flags: flags).map(Strings.Kinds.singular)
        if let kind { metadata.append(.label(Strings.Detail.kind, value: kind)) }
        if !item.isFolder || item.isPackage, let size = facts.size ?? entry?.size.map(Int64.init) {
            metadata.append(
                .label(Strings.Detail.size, value: Strings.Detail.size(size, locale: feature.context.clock.locale)))
        }
        if let created = facts.created { metadata.append(.date(Strings.Detail.created, created)) }
        let indexed = entry.map { Date(timeIntervalSince1970: TimeInterval($0.modified)) }
        if let modified = facts.modified ?? indexed { metadata.append(.date(Strings.Detail.modified, modified)) }
        metadata.append(.label(Strings.Detail.location, value: Paths.display(Paths.parent(of: path), home: plan.home)))
        return Detail(.preview(FileRows.url(of: row)), metadata: metadata)
    }

    func actions(for row: Row) -> [Action] {
        feature.fileActions.actions(for: row)
    }

    @concurrent private static func entry(at path: String, in index: FileIndex) async -> FileEntry? {
        guard let snapshot = try? index.snapshot(), let id = snapshot.lookup(path: path) else { return nil }
        return snapshot.entry(id)
    }
}
