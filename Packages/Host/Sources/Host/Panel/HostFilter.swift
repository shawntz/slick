import Kit

/// Host filtering of a list or grid: the rules `ListSource` documents and `FeatureHarness` models.
///
/// Sections keep their order. A section hidden by its ``SectionVisibility`` is left out, and so is a
/// section with no match. Inside a section, rows order by match tier, then by ``Row/rankHint``,
/// higher first, then by the index's own order, so a weaker tier never outranks a stronger one.
///
/// The result names rows by position in the loaded sections and copies no row, so filtering
/// thousands of rows per keystroke costs what the matches cost.
nonisolated struct HostFilter {
    /// One shown section: positions of its rows in the loaded section, in display order.
    struct Shown: Equatable {
        /// The section's index in the loaded sections.
        var section: Int
        /// Row indices in the loaded section, in display order.
        var rows: [Int]
        /// One entry per row: the matched ranges of its title in UTF-16 offsets. Empty when nothing
        /// was matched, as with an empty query.
        var highlights: [[Range<Int>]]
    }

    /// Where each indexed entry sits: section and row in the loaded sections.
    var positions: [(section: Int, row: Int)] = []

    /// The entries to index, title and keywords per row, with their positions.
    static func entries(for sections: [ListSection]) -> (entries: [FuzzyEntry], positions: [(section: Int, row: Int)]) {
        var entries: [FuzzyEntry] = []
        var positions: [(section: Int, row: Int)] = []
        for (sectionIndex, section) in sections.enumerated() {
            for (rowIndex, row) in section.rows.enumerated() {
                entries.append(FuzzyEntry(title: row.title, keywords: row.keywords))
                positions.append((sectionIndex, rowIndex))
            }
        }
        return (entries, positions)
    }

    /// The sections shown for `query`, given the index's matches for it. Nil matches, as with an
    /// empty query or an index not built yet, shows every visible row in load order.
    func filter(_ loaded: [ListSection], query: String, matches: [FuzzyMatch]?) -> [Shown] {
        guard !query.isEmpty, let matches else {
            var shown: [Shown] = []
            for (index, section) in loaded.enumerated()
            where section.isVisible(forQuery: query) && !section.rows.isEmpty {
                shown.append(Shown(section: index, rows: Array(section.rows.indices), highlights: []))
            }
            return shown
        }
        let visible = loaded.map { $0.isVisible(forQuery: query) }
        var found = [[Found]](repeating: [], count: loaded.count)
        for (order, match) in matches.enumerated() {
            guard positions.indices.contains(match.index) else { continue }
            let position = positions[match.index]
            guard visible[position.section], loaded[position.section].rows.indices.contains(position.row) else {
                continue
            }
            found[position.section].append(
                Found(
                    row: position.row, tier: match.tier,
                    hint: loaded[position.section].rows[position.row].rankHint, order: order,
                    highlights: match.highlights))
        }
        var shown: [Shown] = []
        for (section, rows) in found.enumerated() where !rows.isEmpty {
            let ordered = rows.sorted { lhs, rhs in
                if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
                if lhs.hint != rhs.hint { return lhs.hint > rhs.hint }
                return lhs.order < rhs.order
            }
            shown.append(Shown(section: section, rows: ordered.map(\.row), highlights: ordered.map(\.highlights)))
        }
        return shown
    }

    private struct Found {
        var row: Int
        var tier: MatchTier
        var hint: Double
        var order: Int
        var highlights: [Range<Int>]
    }
}
