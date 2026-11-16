import Kit
import KitTesting
import Testing

@testable import Emoji

/// A harness over the fakes with the data loaded, as after activation in the app.
func loadedHarness(_ fakes: FakeServices = FakeServices()) async -> FeatureHarness<EmojiFeature> {
    let harness = FeatureHarness(EmojiFeature.self, fakes: fakes)
    await harness.activate()
    await harness.feature.waitUntilLoaded()
    return harness
}

/// The bundled catalog, parsed once for the tests that read it.
let bundledCatalog: EmojiCatalog = {
    do {
        return try EmojiCatalog.parse(EmojiData.text)
    } catch {
        Issue.record("the bundled data does not parse: \(error)")
        return EmojiCatalog(entries: [])
    }
}()

/// The entry for a glyph in the bundled catalog.
func entry(_ glyph: String) throws -> EmojiEntry {
    try #require(bundledCatalog.entry(forKey: EmojiEntry.key(for: glyph)), "no entry for \(glyph)")
}

/// The row ID of an emoji or symbol.
func emojiID(_ glyph: String) -> ItemID {
    ItemID(EmojiLibrary.namespace, EmojiEntry.key(for: glyph))
}

extension FeatureHarness {
    /// The titles of the visible rows, in order, at most `limit`.
    func titles(_ limit: Int = .max) -> [String] {
        Array(rows.prefix(limit).map(\.title))
    }
}

/// The grid's search rows with default options, and KitTesting's index over them twice: titles and
/// keywords, and titles alone. Built once, because the catalog is large.
private let searchGrid: (rows: [Row], index: SimpleFuzzyIndex, titles: SimpleFuzzyIndex) = {
    let rows = EmojiRows.build(bundledCatalog, EmojiRows.Options()).last?.rows ?? []
    return (
        rows, SimpleFuzzyIndex(rows.map { FuzzyEntry(title: $0.title, keywords: $0.keywords) }),
        SimpleFuzzyIndex(rows.map { FuzzyEntry(title: $0.title, keywords: []) })
    )
}()

/// The grid's rows for a query in the order the host shows them, over KitTesting's index: by tier,
/// then a title match before a match that only a keyword reaches, then rank hint, then the index's
/// own order. A row matches by title when its title alone reaches the tier of its best match.
func gridOrder(_ query: String) -> [Row] {
    let (results, index, titles) = searchGrid
    var titleTiers: [Int: MatchTier] = [:]
    for match in titles.search(query, limit: .max) { titleTiers[match.index] = match.tier }
    return index.search(query, limit: .max).enumerated().sorted { lhs, rhs in
        if lhs.element.tier != rhs.element.tier { return lhs.element.tier < rhs.element.tier }
        let lhsTitle = titleTiers[lhs.element.index] == lhs.element.tier
        let rhsTitle = titleTiers[rhs.element.index] == rhs.element.tier
        if lhsTitle != rhsTitle { return lhsTitle }
        let lhsHint = results[lhs.element.index].rankHint
        let rhsHint = results[rhs.element.index].rankHint
        if lhsHint != rhsHint { return lhsHint > rhsHint }
        return lhs.offset < rhs.offset
    }.map { results[$0.element.index] }
}

/// True when the row's title alone matches the query as well as the row does.
func matchesByTitle(_ row: Row, _ query: String) -> Bool {
    let full = SimpleFuzzyIndex([FuzzyEntry(title: row.title, keywords: row.keywords)]).search(query, limit: 1)
    let title = SimpleFuzzyIndex([FuzzyEntry(title: row.title, keywords: [])]).search(query, limit: 1)
    return !title.isEmpty && title.first?.tier == full.first?.tier
}
