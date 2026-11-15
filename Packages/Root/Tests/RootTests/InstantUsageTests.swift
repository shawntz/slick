import Foundation
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Testing

@testable import Root

/// Glyphs as the Emoji feature has them: a colon search that claims the top with `.learnOnly` rows,
/// and a grid whose Recently Used section reads the usage service, all in one namespace.
final class GlyphFeature: Feature {
    static let manifest = FeatureManifest(id: "glyphs", name: "Glyphs", icon: .symbol("face.smiling"))
    nonisolated static let namespace = "glyph"
    static let names = ["smile": "Smiling Face", "sun": "Sun", "star": "Star"]

    let colon = ColonGlyphs()
    let grid: GlyphGrid

    init(context: FeatureContext) {
        grid = GlyphGrid(usage: context.usage)
    }

    var liveProviders: [LiveProvider] { [.instant(colon)] }

    static func row(_ key: String, memory: RowMemory = .learnOnly) -> Row {
        Row(id: ItemID(namespace, key), title: names[key] ?? key, memory: memory)
    }
}

final class ColonGlyphs: InstantProvider {
    let namespace = GlyphFeature.namespace
    var memory: RowMemory = .learnOnly

    func answer(for query: String) -> InstantAnswer? {
        guard query.first == ":" else { return nil }
        let typed = query.dropFirst()
        let rows = GlyphFeature.names.keys.sorted().filter { $0.hasPrefix(typed) }.map {
            GlyphFeature.row($0, memory: memory)
        }
        return rows.isEmpty ? nil : InstantAnswer(rows: rows, claimsTop: true)
    }

    func actions(for row: Row) -> [Action] {
        [Action.paste(row.title).recordingUse()]
    }
}

final class GlyphGrid: ListSource {
    let usage: any UsageService

    init(usage: any UsageService) {
        self.usage = usage
    }

    func load(_ request: ListRequest) async throws -> ListResult {
        let recent = usage.recentlyUsed(namespace: GlyphFeature.namespace, limit: 8).map { GlyphFeature.row($0.id.key) }
        let all = GlyphFeature.names.keys.sorted().map { GlyphFeature.row($0) }
        return ListResult(sections: [
            ListSection("Recently Used", id: "recent", visibility: .whenQueryEmpty, rows: recent),
            ListSection("All", id: "all", rows: all),
        ])
    }

    func actions(for row: Row) -> [Action] { [] }
}

@Suite(.timeLimit(.minutes(1))) struct InstantUsageTests {
    /// The fixture with the glyph feature over root search's own usage service, as App wires the
    /// features' services to Root through forwarders.
    private func glyphFixture() async -> (RootFixture, GlyphFeature) {
        let fixture = await RootFixture.ready()
        var services = fixture.fakes.services
        services.usage = fixture.root.usage
        let context = FeatureContext(featureID: GlyphFeature.manifest.id, environment: .selftest, services: services)
        let feature = GlyphFeature(context: context)
        fixture.directory.entries.append(FeatureEntry(reading: feature, context: context, isEnabled: true))
        await fixture.settle()
        return (fixture, feature)
    }

    private func recentTitles(_ grid: GlyphGrid) async throws -> [String] {
        let result = try await grid.load(ListRequest())
        return result.sections.first { $0.id == "recent" }?.rows.map(\.title) ?? []
    }

    @Test func aGlyphPickedFromAColonSearchFillsTheGridsRecentlyUsed() async throws {
        let (fixture, feature) = await glyphFixture()
        #expect(try await recentTitles(feature.grid).isEmpty)

        try await fixture.pick("Sun", for: ":su")
        fixture.clock.advance(by: .seconds(60))
        try await fixture.pick("Smiling Face", for: ":sm")

        let sun = ItemID(GlyphFeature.namespace, "sun")
        #expect(fixture.root.usage.useCount(of: sun) == 1)
        #expect(fixture.root.usage.frecency(namespace: GlyphFeature.namespace)[sun] != nil)
        #expect(try await recentTitles(feature.grid) == ["Smiling Face", "Sun"])
        // A learn-only row keeps no snapshot and never joins the catalog.
        #expect(fixture.root.usage.recentlyUsed(namespace: GlyphFeature.namespace, limit: 1).first?.snapshot == nil)
        #expect(fixture.root.row(for: sun) == nil)
        await fixture.shutdown()
    }

    @Test func aRowThatAsksForNothingIsNotRecorded() async throws {
        let (fixture, feature) = await glyphFixture()
        feature.colon.memory = .never
        try await fixture.pick("Star", for: ":st")
        #expect(fixture.root.usage.useCount(of: ItemID(GlyphFeature.namespace, "star")) == 0)
        #expect(try await recentTitles(feature.grid).isEmpty)
        await fixture.shutdown()
    }

    @Test func nothingIsRecordedWhileLearningIsPaused() async throws {
        let (fixture, feature) = await glyphFixture()
        fixture.general[HostSettings.learningPaused] = true
        await fixture.settle()
        try await fixture.pick("Sun", for: ":su")
        #expect(try await recentTitles(feature.grid).isEmpty)
        await fixture.shutdown()
    }
}
