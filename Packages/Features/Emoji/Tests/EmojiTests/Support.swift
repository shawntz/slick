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

/// The grid's rows for a query, in the order the host shows them: KitTesting's harness filters as
/// the host does.
func gridRows(_ query: String) async throws -> [Row] {
    let harness = await loadedHarness()
    try await harness.run("search")
    try await harness.setQuery(query)
    return harness.rows
}

/// The titles of ``gridRows(_:)``.
func gridTitles(_ query: String) async throws -> [String] {
    try await gridRows(query).map(\.title)
}

/// True when the row's title made its best match, rather than a keyword alone.
func matchesByTitle(_ row: Row, _ query: String) -> Bool {
    let entry = FuzzyEntry(title: row.title, keywords: row.keywords)
    return SimpleFuzzyIndex([entry]).search(query, limit: 1).first?.matchesTitle ?? false
}
