import Foundation
import Kit
import KitTesting
import Testing

@testable import Quicklinks

/// Large and odd files, and text that is not the feature's.
@Suite("Scale and hostile input", .timeLimit(.minutes(1)))
@MainActor
struct ScaleTests {
    /// Many quicklinks, half with an argument, every domain a reserved example one.
    static func bigFile(_ count: Int) -> QuicklinkFile {
        QuicklinkFile(
            quicklinks: (0..<count).map { index in
                Quicklink(
                    id: "big-\(index)", name: "Example Link \(index)",
                    link: index.isMultiple(of: 2)
                        ? "https://site\(index).example.com/page" : "https://site\(index).example.com/find?q={query}",
                    keywords: ["k\(index)"])
            }, removedDefaults: DefaultSearches.all.map(\.id))
    }

    @Test func fiftyThousandQuicklinksLoadAndShow() async throws {
        let quicklinks = try await QuicklinksHarness(file: Self.bigFile(50_000))
        let feature = quicklinks.feature
        #expect(feature.entries.count == 50_000)
        #expect(feature.searchEngines.count == 25_000)
        #expect(try await quicklinks.harness.catalogRows().count == 25_000)
        #expect(feature.commands.count == 5 + 25_000)
        #expect(feature.defaultEngine?.id == "big-1", "with Google deleted, the first search stands in")

        try await quicklinks.harness.run("search")
        try await quicklinks.harness.setQuery("Example Link 49999")
        #expect(quicklinks.harness.rows.first?.title == "Example Link 49999")
        #expect(quicklinks.harness.issues.isEmpty)
    }

    @Test func aHandWrittenFileWithHugeAndMultiLineValuesStillLoads() async throws {
        let huge = "https://docs.example.com/" + String(repeating: "a", count: 1_000_000)
        let raw = """
            {"quicklinks": [
              {"id": "huge", "name": "Huge", "link": "\(huge)"},
              {"id": "lines", "name": "First\\nSecond\\r\\nThird", "link": "https://docs.example.com"},
              {"id": "ممر", "name": "عربي ‮ mixed", "link": "https://docs.example.com/{query}"},
              {"id": "\(String(repeating: "x", count: 64))", "name": "Long ID", "link": "https://a.example.com"},
              {"id": "\(String(repeating: "x", count: 64))", "name": "Same Long ID", "link": "https://b.example.com"}
            ], "removedDefaults": \(DefaultSearches.all.map(\.id))}
            """
        let quicklinks = try await QuicklinksHarness(raw: raw)
        let entries = quicklinks.feature.entries
        #expect(entries.count == 5)
        #expect(entries[1].quicklink.name == "First Second Third")
        #expect(entries.allSatisfy { Quicklink.isValidID($0.id) })
        #expect(Set(entries.map(\.id)).count == 5)
        #expect(quicklinks.feature.status == nil)

        // A save writes the cleaned file, and the next read leaves every ID as it is.
        try await quicklinks.feature.setEnabled(false, id: "lines")
        let ids = quicklinks.feature.entries.map(\.id)
        let stored = try #require(try await quicklinks.storedFile())
        #expect(stored.prepared().quicklinks.map(\.id) == ids)
    }

    @Test(arguments: ["/usr/local", "~/notes", ":smile", "=1+1", ">ls", "?help", "-example.com", ".example.com"])
    func textThatStartsWithAnotherFeaturesPrefixIsNotAnAddress(text: String) async throws {
        let quicklinks = try await QuicklinksHarness()
        #expect(AddressDetector.detect(text) == nil)
        #expect(quicklinks.harness.instantAnswers(for: text).isEmpty)
    }

    @Test func aHugeSelectionIsReadOnlyAsFarAsTheSearchNeeds() {
        let words = String(repeating: "word ", count: 2_000_000)
        let prepared = SearchText.prepare("\n  " + words)
        #expect(prepared.count == SearchText.maximumLength - 1, "no space at the end")
        #expect(prepared.hasPrefix("word word"))
        #expect(!prepared.hasSuffix(" "))
        #expect(SearchText.prepare("a\u{2028}b\u{00A0}c") == "a b c")
    }

    @Test func turningTheFeatureOffAndOnKeepsOneWatch() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.samplesOnly)
        await quicklinks.harness.deactivate()
        await quicklinks.harness.activate()
        await quicklinks.harness.activate()
        let signal = try #require(quicklinks.feature.declarationChanges)
        let before = signal.generation
        var edited = Samples.samplesOnly
        edited.quicklinks[0].name = "Renamed Docs"
        try await quicklinks.editFileOnDisk(edited)
        #expect(quicklinks.feature.entries.first?.quicklink.name == "Renamed Docs")
        #expect(signal.generation == before + 1, "one edit, one signal")
    }
}
