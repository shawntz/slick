import Kit

/// How emoji rank against each other when they match a query equally well: pins first, then recent
/// use, then the emoji people use most, then the order of the grid.
nonisolated enum EmojiRanking {
    /// A use counts this much more than the whole static score, so any recent use wins.
    static let usageWeight = 1_000.0
    /// A pin outweighs any amount of use.
    static let pinWeight = 1_000_000_000.0

    /// The score without usage: a common emoji gets 200 minus its rank, and every entry gets less
    /// than 1 for its position, so the order of the grid breaks the remaining ties.
    static func staticScore(_ entry: EmojiEntry, position: Int, count: Int) -> Double {
        let common = entry.commonRank > 0 ? Double(max(1, 200 - entry.commonRank)) : 0
        return common + 1 - Double(position) / Double(max(count, 1))
    }

    /// The full score, given the item's frecency from the usage service.
    static func score(_ entry: EmojiEntry, position: Int, count: Int, frecency: Double) -> Double {
        staticScore(entry, position: position, count: count) + frecency * usageWeight
    }
}

/// Builds the grid's rows and the colon search's rows. Rows are plain values: building them needs
/// no state, so the grid builds its rows off the main thread.
nonisolated enum EmojiRows {
    /// What the grid shows.
    struct Options: Sendable {
        var tone: SkinTone = .none
        var includeSymbols = true
        /// The group picked in the category dropdown; nil for all of them.
        var group: EmojiGroup?
        /// Keys of recently used items, most recent first.
        var recentKeys: [String] = []
        var frecency: [ItemID: Double] = [:]
        /// Keys of pinned items, in the order they were pinned.
        var pinnedKeys: [String] = []
    }

    /// The section ID of the pinned emoji.
    static let pinnedSectionID = "pinned"
    /// The section ID of the recently used emoji.
    static let recentSectionID = "recent"
    /// The section ID of the search results, which shows only while the user searches.
    static let resultsSectionID = "results"

    /// The grid's sections. With an empty query: Pinned, Recently Used, then one section per group.
    /// While searching: one section with every match, so the best match comes first whatever its
    /// group, and pins first among equal matches.
    @concurrent static func sections(_ catalog: EmojiCatalog, _ options: Options) async -> [ListSection] {
        build(catalog, options)
    }

    /// The same as ``sections(_:_:)``, on the calling thread, for benchmarks.
    static func build(_ catalog: EmojiCatalog, _ options: Options) -> [ListSection] {
        let count = catalog.entries.count
        var all: [Row] = []
        all.reserveCapacity(count)
        var byGroup = [[Row]](repeating: [], count: EmojiGroup.allCases.count)
        let pinned = Set(options.pinnedKeys)
        for (position, entry) in catalog.entries.enumerated() where allows(entry, options) {
            let id = ItemID(EmojiLibrary.namespace, entry.key)
            var rank = EmojiRanking.score(entry, position: position, count: count, frecency: options.frecency[id] ?? 0)
            if pinned.contains(entry.key) { rank += EmojiRanking.pinWeight }
            let row = row(entry, id: id, tone: options.tone, rankHint: rank)
            all.append(row)
            byGroup[entry.group.rawValue].append(row)
        }
        var sections: [ListSection] = []
        if options.group == nil {
            func rows(_ keys: [String]) -> [Row] {
                var seen = Set<String>()
                return keys.compactMap { key -> Row? in
                    guard seen.insert(key).inserted, let entry = catalog.entry(forKey: key), allows(entry, options)
                    else { return nil }
                    return row(entry, id: ItemID(EmojiLibrary.namespace, key), tone: options.tone)
                }
            }
            let pins = rows(options.pinnedKeys)
            if !pins.isEmpty {
                sections.append(
                    ListSection(
                        EmojiStrings.pinnedSection, id: pinnedSectionID, visibility: .whenQueryEmpty, rows: pins))
            }
            // A pinned emoji shows once, under Pinned.
            let recent = rows(options.recentKeys.filter { !pinned.contains($0) })
            if !recent.isEmpty {
                sections.append(
                    ListSection(
                        EmojiStrings.recentlyUsed, id: recentSectionID, visibility: .whenQueryEmpty, rows: recent))
            }
        }
        for group in EmojiGroup.allCases where !byGroup[group.rawValue].isEmpty {
            sections.append(
                ListSection(
                    EmojiStrings.groupTitle(group), id: group.id, visibility: .whenQueryEmpty,
                    rows: byGroup[group.rawValue]))
        }
        sections.append(ListSection(nil, id: resultsSectionID, visibility: .whenSearching, rows: all))
        return sections
    }

    /// One emoji or symbol as a row: the glyph in the tone is the cell's content and the payload.
    static func row(
        _ entry: EmojiEntry, id: ItemID? = nil, tone: SkinTone, rankHint: Double = 0, subtitle: String? = nil
    ) -> Row {
        let glyph = entry.glyph(in: tone)
        return Row(
            id: id ?? ItemID(EmojiLibrary.namespace, entry.key), title: entry.name, subtitle: subtitle,
            icon: .glyph(glyph), keywords: entry.keywords, payload: Payload(glyph), rankHint: rankHint,
            memory: .learnOnly)
    }

    private static func allows(_ entry: EmojiEntry, _ options: Options) -> Bool {
        (options.includeSymbols || entry.group.isEmoji) && (options.group == nil || options.group == entry.group)
    }
}
