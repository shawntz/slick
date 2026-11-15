import Foundation
import Kit

/// One page on the harness's stack, with what the host would be showing for it.
@MainActor public final class PageState {
    public let page: Page
    /// The search field's text.
    public internal(set) var query = ""
    /// The selected filter option's ID, for pages with a dropdown.
    public internal(set) var filter: String?
    /// The dropdown shown now: the page's, or the last one a load returned.
    public internal(set) var dropdown: FilterDropdown?
    /// The sections as the source returned them, before host filtering.
    public internal(set) var loadedSections: [ListSection] = []
    /// The sections the user sees.
    public internal(set) var sections: [ListSection] = []
    /// The selected row's ID. The host selects the first row after each load unless the selected
    /// row is still visible.
    public internal(set) var selectedID: ItemID?
    /// The section of the selected row, since one row may appear in two sections.
    public internal(set) var selectedSection: String?
    /// The refresh delay from the last load, if any.
    public internal(set) var refreshAfter: Duration?
    /// The token for the next page of a paged result, if more rows exist.
    public internal(set) var nextPage: ListPageToken?
    /// The empty state shown when there are no rows.
    public internal(set) var emptyState: EmptyState?
    /// The banner from the last load, if any.
    public internal(set) var notice: Notice?
    /// What a detail page shows.
    public internal(set) var detail = Detail()
    /// A form page's values.
    public internal(set) var formValues = FormValues()
    /// A form page's errors from the last submit.
    public internal(set) var formErrors: [String: FieldError] = [:]

    var index: (any FuzzyIndex)?
    var positions: [(section: Int, row: Int)] = []
    /// The source's change signal generation and settings when it last loaded, to tell a stale page.
    var loadedGeneration = 0
    var loadedSettings: [SettingStorage] = []

    init(_ page: Page) {
        self.page = page
        switch page {
        case .list(let list): (dropdown, query) = (list.filter, list.initialQuery)
        case .grid(let grid): (dropdown, query) = (grid.filter, grid.initialQuery)
        case .form(let form): formValues = form.initialValues
        case .detail: break
        }
        filter = dropdown?.defaultID
    }

    /// The visible rows, in order.
    public var rows: [Row] { sections.flatMap(\.rows) }

    /// The selected row.
    public var selectedRow: Row? {
        guard let selectedID else { return nil }
        let inSection = sections.first { $0.id == selectedSection }?.rows.first { $0.id == selectedID }
        return inSection ?? rows.first { $0.id == selectedID }
    }

    var listSource: (any ListSource)? {
        switch page {
        case .list(let list): list.source
        case .grid(let grid): grid.source
        case .detail, .form: nil
        }
    }

    var pageEmptyState: EmptyState? {
        switch page {
        case .list(let list): list.emptyState
        case .grid(let grid): grid.emptyState
        case .detail, .form: nil
        }
    }

    /// Applies host filtering: sections hidden by their visibility, matching rows by tier and then
    /// rank hint inside their section, empty sections hidden.
    func filterLoadedSections() {
        let shown = loadedSections.map { $0.isVisible(forQuery: query) }
        guard !query.isEmpty, let index else {
            sections = zip(loadedSections, shown).filter { $0.1 && !$0.0.rows.isEmpty }.map(\.0)
            return
        }
        var matchesBySection = [[(row: Row, tier: MatchTier)]](repeating: [], count: loadedSections.count)
        for match in index.search(query, limit: Int.max) {
            let position = positions[match.index]
            guard shown[position.section] else { continue }
            matchesBySection[position.section].append(
                (loadedSections[position.section].rows[position.row], match.tier))
        }
        sections = zip(loadedSections, matchesBySection).compactMap { section, matches in
            guard !matches.isEmpty else { return nil }
            var filtered = section
            // Stable: equal tier and hint keep the engine's order.
            filtered.rows = matches.enumerated().sorted { lhs, rhs in
                if lhs.element.tier != rhs.element.tier { return lhs.element.tier < rhs.element.tier }
                if lhs.element.row.rankHint != rhs.element.row.rankHint {
                    return lhs.element.row.rankHint > rhs.element.row.rankHint
                }
                return lhs.offset < rhs.offset
            }.map(\.element.row)
            return filtered
        }
    }

    func keepSelectionVisible() {
        if let selectedID, let section = sections.first(where: { $0.id == selectedSection }),
            section.rows.contains(where: { $0.id == selectedID })
        {
            return
        }
        if let selectedID, let section = sections.first(where: { $0.rows.contains { $0.id == selectedID } }) {
            selectedSection = section.id
            return
        }
        let first = sections.first { !$0.rows.isEmpty }
        selectedID = first?.rows.first?.id
        selectedSection = first?.id
    }

    func select(_ id: ItemID) {
        selectedID = id
        selectedSection = sections.first { $0.rows.contains { $0.id == id } }?.id
    }
}
