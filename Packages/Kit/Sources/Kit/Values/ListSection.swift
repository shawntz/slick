/// A titled group of rows in a list or grid.
///
/// One row may appear in more than one section, such as in "Recently Used" and in its category:
/// the host keys the selection by section ID and row ID.
public struct ListSection: Identifiable, Hashable, Sendable {
    /// Stable within one page, so the host can keep scroll position and selection.
    public var id: String
    /// The heading. Nil draws the rows without one.
    public var title: String?
    /// Text drawn after the heading. For a count, set ``showsCount`` instead, which stays right
    /// while the host filters.
    public var subtitle: String?
    /// True draws the number of visible rows after the heading.
    public var showsCount: Bool
    /// When the section shows, by whether the user is searching.
    public var visibility: SectionVisibility
    public var rows: [Row]

    /// Makes a section. The ID defaults to the title.
    public init(
        _ title: String? = nil, id: String? = nil, subtitle: String? = nil, showsCount: Bool = false,
        visibility: SectionVisibility = .always, rows: [Row]
    ) {
        self.id = id ?? title ?? ""
        self.title = title
        self.subtitle = subtitle
        self.showsCount = showsCount
        self.visibility = visibility
        self.rows = rows
    }

    /// True when the section shows for this search text.
    public func isVisible(forQuery query: String) -> Bool {
        switch visibility {
        case .always: true
        case .whenQueryEmpty: query.isEmpty
        case .whenSearching: !query.isEmpty
        }
    }
}

/// When a section shows.
public enum SectionVisibility: Hashable, Sendable {
    /// Always, the default.
    case always
    /// Only while the search field is empty, such as "Pinned" or "Recently Used", whose rows also
    /// appear in another section.
    case whenQueryEmpty
    /// Only while the user is searching.
    case whenSearching
}
