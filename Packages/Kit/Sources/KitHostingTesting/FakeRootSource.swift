import Foundation
import Kit
import KitHosting

/// Root search over a fixed list of rows, for Host tests that drive the panel without Root.
///
/// The empty query shows every row in a Suggested section. A typed query keeps the rows whose title
/// contains it, ignoring case, in a Results section, followed by ``fallbacks``. It records every
/// call, so a test can check the order of ``begin()``, ``update(query:)`` and ``end()``.
@MainActor public final class FakeRootSource: RootSource {
    /// One call the host made.
    public enum Call: Hashable, Sendable {
        case begin
        case update(String)
        case end
        case didRun(ItemID, LaunchSource)
        case forget(ItemID)
    }

    public let changes = ChangeSignal()
    /// The rows root search searches.
    public var rows: [Row]
    /// Rows of the fallbacks section, shown for every typed query.
    public var fallbacks: [Row]
    /// Feature IDs by ``ItemID`` namespace, for ``featureID(for:)``. A `cmd:` row's feature comes
    /// from its ID.
    public var featureIDs: [String: String] = [:]
    /// The actions of a row that is not a command. Default none.
    public var rowActions: @MainActor (Row) -> [Action] = { _ in [] }
    /// When true, every typed query's snapshot says an async provider is still working, until
    /// ``simulateLateSection(_:)``.
    public var marksQueriesLoading = false
    /// The Tab command every typed query's snapshot carries, as Root fills
    /// ``RootSnapshot/tabCommand``. Default nil.
    public var tabCommand: ItemID?

    /// Every call, in order.
    public private(set) var calls: [Call] = []
    public private(set) var snapshot = RootSnapshot()
    /// True between ``begin()`` and ``end()``.
    public private(set) var isInSession = false

    public init(rows: [Row], fallbacks: [Row] = []) {
        self.rows = rows
        self.fallbacks = fallbacks
    }

    public func begin() -> RootSnapshot {
        calls.append(.begin)
        isInSession = true
        snapshot = makeSnapshot(query: "")
        return snapshot
    }

    public func update(query: String) -> RootSnapshot {
        calls.append(.update(query))
        snapshot = makeSnapshot(query: query)
        return snapshot
    }

    public func end() {
        calls.append(.end)
        isInSession = false
    }

    /// No actions for a command row, as the contract says; ``rowActions`` for every other row.
    public func actions(for row: Row) -> [Action] {
        row.id.namespace == ItemID.ReservedNamespace.command ? [] : rowActions(row)
    }

    /// The first case-insensitive occurrence of the current query in the title.
    public func titleHighlights(for row: Row) -> [Range<Int>] {
        Self.highlights(of: snapshot.query, in: row.title)
    }

    public func featureID(for row: Row) -> String? {
        if row.id.namespace == ItemID.ReservedNamespace.command {
            return row.id.key.split(separator: ".", maxSplits: 1).first.map(String.init)
        }
        return featureIDs[row.id.namespace]
    }

    public func row(for id: ItemID) -> Row? {
        (rows + fallbacks).first { $0.id == id }
    }

    public func didRun(_ row: Row, launch: LaunchSource) {
        calls.append(.didRun(row.id, launch))
    }

    public func forget(_ id: ItemID) {
        calls.append(.forget(id))
    }

    /// Appends a section to the current snapshot, as an async provider that finished would, ends
    /// loading, and sends ``changes``.
    public func simulateLateSection(_ section: RootSection) {
        let index = snapshot.sections.firstIndex { $0.kind == .fallbacks } ?? snapshot.sections.endIndex
        snapshot.sections.insert(section, at: index)
        snapshot.isLoading = false
        snapshot.revision += 1
        changes.send()
    }

    private func makeSnapshot(query: String) -> RootSnapshot {
        let revision = snapshot.revision + 1
        guard !query.isEmpty else {
            let suggested = RootSection(id: "suggested", title: "Suggested", rows: rows, kind: .suggested)
            let sections = rows.isEmpty ? [] : [suggested]
            return RootSnapshot(sections: sections, revision: revision)
        }
        var matches = rows.filter { $0.title.range(of: query, options: .caseInsensitive) != nil }
        for index in matches.indices.prefix(12) {
            matches[index].titleHighlights = Self.highlights(of: query, in: matches[index].title)
        }
        var sections: [RootSection] = []
        if !matches.isEmpty {
            sections.append(RootSection(id: "results", title: "Results", rows: matches, kind: .results))
        }
        if !fallbacks.isEmpty {
            let title = "Use \"\(query)\" with"
            sections.append(RootSection(id: "fallbacks", title: title, rows: fallbacks, kind: .fallbacks))
        }
        let completion = matches.first { $0.title.lowercased().hasPrefix(query.lowercased()) }.map { row in
            RootCompletion(id: row.id, text: query + row.title.dropFirst(query.count))
        }
        return RootSnapshot(
            query: query, sections: sections, completion: completion, isLoading: marksQueriesLoading,
            emptyState: sections.isEmpty ? EmptyState(title: "No Results") : nil, revision: revision,
            tabCommand: tabCommand)
    }

    private static func highlights(of query: String, in title: String) -> [Range<Int>] {
        guard !query.isEmpty, let range = title.range(of: query, options: .caseInsensitive) else { return [] }
        let start = title.utf16.distance(from: title.startIndex, to: range.lowerBound)
        return [start..<(start + title.utf16.distance(from: range.lowerBound, to: range.upperBound))]
    }
}
