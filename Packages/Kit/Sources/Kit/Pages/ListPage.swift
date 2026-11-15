/// A list page: rows in sections, from a ``ListSource``.
public struct ListPage: Sendable {
    public var source: any ListSource
    /// Shown in the navigation bar.
    public var title: String?
    /// The search field's placeholder, such as "Search clipboard history".
    public var searchPlaceholder: String?
    /// A dropdown beside the search field (Command-P), such as a type filter.
    public var filter: FilterDropdown?
    /// True shows a detail pane beside the rows, filled by ``ListSource/detail(for:)``.
    public var showsDetail: Bool
    /// Shown when there are no rows.
    public var emptyState: EmptyState?
    /// Text already in the search field when the page opens, such as a fallback's typed text.
    public var initialQuery: String

    public init(
        _ source: any ListSource,
        title: String? = nil,
        searchPlaceholder: String? = nil,
        filter: FilterDropdown? = nil,
        showsDetail: Bool = false,
        emptyState: EmptyState? = nil,
        initialQuery: String = ""
    ) {
        self.source = source
        self.title = title
        self.searchPlaceholder = searchPlaceholder
        self.filter = filter
        self.showsDetail = showsDetail
        self.emptyState = emptyState
        self.initialQuery = initialQuery
    }

    /// A page over rows known up front, filtered by the host, such as the links found in a selection.
    /// `actions` makes each row's actions when the host asks.
    @MainActor public init(
        sections: [ListSection], title: String? = nil, searchPlaceholder: String? = nil,
        emptyState: EmptyState? = nil, actions: @escaping @MainActor @Sendable (Row) -> [Action]
    ) {
        self.init(
            StaticListSource(sections: sections, actions: actions), title: title,
            searchPlaceholder: searchPlaceholder, emptyState: emptyState)
    }
}

/// A list source over fixed rows.
@MainActor final class StaticListSource: ListSource {
    private let sections: [ListSection]
    private let makeActions: @MainActor @Sendable (Row) -> [Action]

    init(sections: [ListSection], actions: @escaping @MainActor @Sendable (Row) -> [Action]) {
        self.sections = sections
        self.makeActions = actions
    }

    func load(_ request: ListRequest) async throws -> ListResult {
        ListResult(sections: sections)
    }

    func actions(for row: Row) -> [Action] {
        makeActions(row)
    }
}

/// A grid page: the same source as a list, drawn as cells. Each row's icon fills its cell; the title
/// is drawn under it when ``showsTitles`` is true.
public struct GridPage: Sendable {
    public var source: any ListSource
    public var title: String?
    public var searchPlaceholder: String?
    public var filter: FilterDropdown?
    /// Cells per row. The user can change it with Command-plus and Command-minus.
    public var columns: Int
    /// Cell width divided by height.
    public var aspectRatio: Double
    public var showsTitles: Bool
    public var emptyState: EmptyState?
    /// Text already in the search field when the page opens.
    public var initialQuery: String

    public init(
        _ source: any ListSource,
        title: String? = nil,
        searchPlaceholder: String? = nil,
        filter: FilterDropdown? = nil,
        columns: Int = 8,
        aspectRatio: Double = 1,
        showsTitles: Bool = false,
        emptyState: EmptyState? = nil,
        initialQuery: String = ""
    ) {
        self.source = source
        self.title = title
        self.searchPlaceholder = searchPlaceholder
        self.filter = filter
        self.columns = columns
        self.aspectRatio = aspectRatio
        self.showsTitles = showsTitles
        self.emptyState = emptyState
        self.initialQuery = initialQuery
    }
}

/// A dropdown that narrows a page, such as "All types", "Text", "Images".
public struct FilterDropdown: Sendable {
    public var title: String
    public var options: [FilterOption]
    /// The option selected when the page opens, and whenever a remembered or selected option is no
    /// longer offered.
    public var defaultID: String
    /// True remembers the user's choice across openings of the page.
    public var remembersSelection: Bool

    public init(title: String, options: [FilterOption], defaultID: String? = nil, remembersSelection: Bool = true) {
        self.title = title
        self.options = options
        self.defaultID = defaultID ?? options.first?.id ?? ""
        self.remembersSelection = remembersSelection
    }
}

/// One option in a filter dropdown.
public struct FilterOption: Hashable, Sendable {
    public var id: String
    public var title: String
    public var icon: Icon?
    /// A heading in the dropdown; consecutive options with the same section are grouped.
    public var section: String?

    public init(id: String, title: String, icon: Icon? = nil, section: String? = nil) {
        self.id = id
        self.title = title
        self.icon = icon
        self.section = section
    }
}
