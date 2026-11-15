import Kit

/// How emoji rank against each other when they match a query in the same tier: pins first, then
/// recent use, then the ten most used emoji in their order. Every other common emoji shares one
/// score and the rest share another, so the matcher orders each group: a name that starts with the
/// query comes before a keyword match, and a shorter name comes first. "grinning" finds Grinning
/// Face before Beaming Face with Smiling Eyes, which only has the keyword, and "heart" still finds
/// Red Heart, one of the ten.
nonisolated enum EmojiRanking {
    /// A use counts this much more than the whole static score, so any recent use wins.
    static let usageWeight = 1_000.0
    /// A pin outweighs any amount of use.
    static let pinWeight = 1_000_000_000.0
    /// How many of the most used emoji keep their own order inside a tier.
    static let leadingCount = 10
    /// The score every common emoji below the leading ones shares.
    static let commonScore = 100.0

    /// The score without usage.
    static func staticScore(_ entry: EmojiEntry) -> Double {
        switch entry.commonRank {
        case 1...leadingCount: commonScore + Double(leadingCount + 1 - entry.commonRank)
        case (leadingCount + 1)...: commonScore
        default: 0
        }
    }

    /// The full score, given the item's frecency from the usage service.
    static func score(_ entry: EmojiEntry, frecency: Double) -> Double {
        staticScore(entry) + frecency * usageWeight
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
        var all: [Row] = []
        all.reserveCapacity(catalog.entries.count)
        var byGroup = [[Row]](repeating: [], count: EmojiGroup.allCases.count)
        let pinned = Set(options.pinnedKeys)
        for entry in catalog.entries where allows(entry, options) {
            let id = ItemID(EmojiLibrary.namespace, entry.key)
            var rank = EmojiRanking.score(entry, frecency: options.frecency[id] ?? 0)
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
