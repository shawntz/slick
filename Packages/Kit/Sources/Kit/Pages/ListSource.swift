/// The data behind a list or grid page: rows, their actions, and their details.
///
/// There are two ways to filter, chosen by ``filtering``:
///
/// - ``ListFiltering/host``, the default and the fast path. The host calls ``load(_:)`` once (and
///   again when the filter dropdown, a ``changes`` signal or a setting in ``reloadsOnSettings`` says
///   so), builds a fuzzy index over every row's title and keywords off the main thread, and filters
///   it on each keystroke itself, with no call into the source. Fifty thousand rows are fine.
///   Matching keeps sections in order, hides empty ones and those whose ``ListSection/visibility``
///   says so, and orders rows inside a section by match tier, then a title match before a row only
///   a keyword reached, then ``Row/rankHint``. A keyword equal to the query is in the exact tier.
/// - ``ListFiltering/custom(debounce:)``. The host calls ``load(_:)`` with each query after the
///   debounce, in a task it cancels when the query changes. Check `Task.isCancelled` or call
///   `try Task.checkCancellation()` between steps. Return rows with ``Row/titleHighlights`` so
///   matches are drawn, and a ``ListResult/nextPage`` token to load long results in pages.
///
/// ``load(_:)`` and ``detail(for:)`` start on the main actor. Build more than a few hundred rows,
/// count words in a large text or parse JSON in a `@concurrent` function and await it.
@MainActor public protocol ListSource: RowSource {
    /// Who filters as the user types. Default ``ListFiltering/host``.
    var filtering: ListFiltering { get }

    /// The rows for a request. With host filtering, the query is always empty.
    func load(_ request: ListRequest) async throws -> ListResult

    /// The detail pane's content for a row. The host calls it after the selection has settled
    /// (debounced, about 50 ms), cancels it if the selection moves, and shows the last result. Return
    /// nil for no detail. Default nil.
    func detail(for row: Row) async throws -> Detail?
}

extension ListSource {
    public var filtering: ListFiltering { .host }
    public func detail(for row: Row) async throws -> Detail? { nil }
}

/// Who filters a list as the user types.
public enum ListFiltering: Hashable, Sendable {
    /// The host filters loaded rows with the fuzzy index.
    case host
    /// The source filters: ``ListSource/load(_:)`` runs for each query after the debounce.
    case custom(debounce: Duration)
}

/// What the host asks a list source for.
public struct ListRequest: Hashable, Sendable {
    /// The search text. Always empty for host filtering.
    public var query: String
    /// The selected ``FilterOption/id`` of the page's dropdown, if it has one.
    public var filter: String?
    /// The token from the previous result's ``ListResult/nextPage`` when the user scrolled near the
    /// end; nil for the first page.
    public var page: ListPageToken?
    /// Why the host is loading.
    public var reason: LoadReason

    public init(query: String = "", filter: String? = nil, page: ListPageToken? = nil, reason: LoadReason = .open) {
        self.query = query
        self.filter = filter
        self.page = page
        self.reason = reason
    }
}

/// Why the host loads a list, so a source can, for example, return cached rows when the page opens
/// and fresh rows after its own change signal.
public enum LoadReason: Hashable, Sendable {
    /// The page was pushed.
    case open
    /// The search text changed, under custom filtering.
    case query
    /// The user picked another filter option.
    case filter
    /// The user scrolled near the end of a paged result.
    case nextPage
    /// The previous result's ``ListResult/refreshAfter`` delay passed.
    case refresh
    /// A change signal, a setting in ``ListSource/reloadsOnSettings``, or an action's
    /// ``ActionContext/reload()``.
    case reload
}

/// Marks where a paged result left off. The source makes it and gets it back unchanged.
public struct ListPageToken: Hashable, Sendable {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }
}

/// What a list source returns.
public struct ListResult: Sendable {
    public var sections: [ListSection]
    /// When set, the host loads again after this delay while the page is visible and the query has
    /// not changed, such as a script filter's `rerun`.
    public var refreshAfter: Duration?
    /// Shown instead of the page's empty state when there are no rows.
    public var emptyState: EmptyState?
    /// More rows exist. The host calls ``ListSource/load(_:)`` with this token when the user scrolls
    /// near the end, and appends the rows: to the section with the same ID, or as new sections.
    /// Honored with custom filtering; host filtering loads everything at once.
    public var nextPage: ListPageToken?
    /// Replaces the page's filter dropdown when set, such as when a tag was added while the page is
    /// open. If the selected option is gone, the host selects the default and loads again.
    public var filter: FilterDropdown?
    /// A banner above the rows that stays while rows are visible, such as "Search is limited: grant
    /// Full Disk Access".
    public var notice: Notice?

    public init(
        sections: [ListSection], refreshAfter: Duration? = nil, emptyState: EmptyState? = nil,
        nextPage: ListPageToken? = nil, filter: FilterDropdown? = nil, notice: Notice? = nil
    ) {
        self.sections = sections
        self.refreshAfter = refreshAfter
        self.emptyState = emptyState
        self.nextPage = nextPage
        self.filter = filter
        self.notice = notice
    }

    /// One untitled section.
    public init(
        rows: [Row], refreshAfter: Duration? = nil, emptyState: EmptyState? = nil, nextPage: ListPageToken? = nil,
        notice: Notice? = nil
    ) {
        self.init(
            sections: [ListSection(rows: rows)], refreshAfter: refreshAfter, emptyState: emptyState,
            nextPage: nextPage, notice: notice)
    }
}

/// What a page shows when it has no rows.
public struct EmptyState: Sendable {
    public var icon: Icon?
    public var title: String
    public var message: String?
    /// Actions offered with the empty state, such as "Create Quicklink".
    public var actions: [Action]

    public init(icon: Icon? = nil, title: String, message: String? = nil, actions: [Action] = []) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actions = actions
    }
}

/// A banner above a page's rows.
public struct Notice: Sendable {
    public var icon: Icon?
    public var title: String
    public var message: String?
    /// A button on the banner, such as "Grant Access", which may declare ``Action/requires``.
    public var action: Action?

    public init(icon: Icon? = nil, title: String, message: String? = nil, action: Action? = nil) {
        self.icon = icon
        self.title = title
        self.message = message
        self.action = action
    }
}
