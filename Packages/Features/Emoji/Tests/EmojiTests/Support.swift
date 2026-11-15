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

/// The grid's rows for a query in the order the app shows them. Host filtering orders by tier, then
/// rank hint, then the matcher's own order. Inside one tier the engine's matcher puts a title match
/// before a keyword match; KitTesting's fake index orders by title length alone, so this applies the
/// engine's rule on top of it.
func gridOrder(_ query: String, options: EmojiRows.Options = EmojiRows.Options()) -> [Row] {
    guard let results = EmojiRows.build(bundledCatalog, options).last?.rows else { return [] }
    let index = SimpleFuzzyIndex(results.map { FuzzyEntry(title: $0.title, keywords: $0.keywords) })
    let matcher = index.search(query, limit: .max).enumerated().sorted { lhs, rhs in
        if lhs.element.tier != rhs.element.tier { return lhs.element.tier < rhs.element.tier }
        let lhsTitle = !lhs.element.highlights.isEmpty
        let rhsTitle = !rhs.element.highlights.isEmpty
        if lhsTitle != rhsTitle { return lhsTitle }
        return lhs.offset < rhs.offset
    }.map(\.element)
    return matcher.enumerated().sorted { lhs, rhs in
        if lhs.element.tier != rhs.element.tier { return lhs.element.tier < rhs.element.tier }
        let lhsHint = results[lhs.element.index].rankHint
        let rhsHint = results[rhs.element.index].rankHint
        if lhsHint != rhsHint { return lhsHint > rhsHint }
        return lhs.offset < rhs.offset
    }.map { results[$0.element.index] }
}
