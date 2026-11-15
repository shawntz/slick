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
