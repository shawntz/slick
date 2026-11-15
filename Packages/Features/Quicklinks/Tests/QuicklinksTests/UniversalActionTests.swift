import Foundation
import Kit
import KitTesting
import Testing

@testable import Quicklinks

@Suite("Universal actions for selected text and links", .timeLimit(.minutes(1)))
@MainActor
struct UniversalActionTests {
    @Test func selectedTextCanBeSearchedWithTheDefaultEngine() async throws {
        let quicklinks = try await QuicklinksHarness()
        let actions = quicklinks.harness.universalActions(for: .text("structured concurrency"))
        #expect(actions.map(\.id) == ["search-web", "search-with"])
        #expect(actions.first?.title == "Search the Web")
        let outcome = try await quicklinks.harness.performUniversal("search-web", on: .text("structured concurrency"))
        #expect(outcome.kind == .close(hud: nil))
        #expect(
            quicklinks.fakes.workspace.opened.map(\.absoluteString) == [
                "https://www.google.com/search?q=structured%20concurrency"
            ])
        #expect(quicklinks.harness.issues.isEmpty)
    }

    @Test func searchWithListsEverySearchThatIsOn() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.file)
        try await quicklinks.feature.setEnabled(false, id: "bing")
        let actions = quicklinks.harness.universalActions(for: .text("kit"))
        let engines = try await quicklinks.harness.submenu("search-with", in: actions, row: nil, launch: .selection)
        let names = engines.map(\.title)
        #expect(names.contains("Search Wikipedia") && names.contains("Sample Search"))
        #expect(!names.contains("Search Bing"))
        #expect(names.contains("Sample Tracker"), "one free text argument takes the text")
        #expect(names.count == quicklinks.feature.searchEngines.count)
        let wikipedia = try #require(engines.first { $0.title == "Search Wikipedia" })
        try await quicklinks.harness.perform(wikipedia, row: nil, query: "kit", launch: .selection)
        #expect(
            quicklinks.fakes.workspace.opened.map(\.absoluteString) == [
                "https://en.wikipedia.org/wiki/Special:Search?search=kit"
            ])
    }

    @Test func aLongSelectionIsOneLineAndCappedForTheSearch() async throws {
        let quicklinks = try await QuicklinksHarness()
        let text = "  first line\n\n  second\tline  " + String(repeating: "x", count: 5000)
        try await quicklinks.harness.performUniversal("search-web", on: .text(text))
        let opened = try #require(quicklinks.fakes.workspace.opened.first?.absoluteString)
        #expect(opened.hasPrefix("https://www.google.com/search?q=first%20line%20second%20line%20xxx"))
        #expect(SearchText.prepare(text).count == SearchText.maximumLength)
        #expect(SearchText.prepare(" \n\t ").isEmpty)
        #expect(quicklinks.harness.universalActions(for: .text("   ")).isEmpty)
    }

    @Test func selectedTextThatIsAnAddressCanBeOpened() async throws {
        let quicklinks = try await QuicklinksHarness()
        let actions = quicklinks.harness.universalActions(for: .text("docs.example.com/guide"))
        #expect(actions.map(\.id) == ["open-link", "search-web", "search-with"])
        try await quicklinks.harness.performUniversal("open-link", on: .text("docs.example.com/guide"))
        #expect(quicklinks.fakes.workspace.opened.map(\.absoluteString) == ["https://docs.example.com/guide"])
    }

    @Test func aSelectedLinkCanBeOpenedOrSaved() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.samplesOnly)
        let url = try #require(URL(string: "https://www.example.com/reports?id=7"))
        let actions = quicklinks.harness.universalActions(for: .url(url))
        #expect(actions.map(\.id) == ["open-link", "save-quicklink"])
        try await quicklinks.harness.performUniversal("open-link", on: .url(url))
        #expect(quicklinks.fakes.workspace.opened == [url])

        try await quicklinks.harness.performUniversal("save-quicklink", on: .url(url))
        #expect(quicklinks.harness.page?.formValues.text("link") == "https://www.example.com/reports?id=7")
        #expect(quicklinks.harness.page?.formValues.text("name") == "example.com")
        try await quicklinks.harness.submit()
        #expect(try await quicklinks.harness.catalogRows().map(\.title).contains("example.com"))
    }

    @Test func aLinkThatIsNotOnTheWebGetsNoActions() async throws {
        let quicklinks = try await QuicklinksHarness()
        let file = try #require(URL(string: "file:///tmp/example.txt"))
        let deep = try #require(URL(string: "x-example-app://open"))
        #expect(quicklinks.harness.universalActions(for: .url(file)).isEmpty)
        #expect(quicklinks.harness.universalActions(for: .url(deep)).isEmpty)
    }

    @Test func anAddressRowGetsSaveAsQuicklinkThroughWhatItStandsFor() async throws {
        let quicklinks = try await QuicklinksHarness()
        let row = try #require(quicklinks.harness.instantAnswers(for: "example.com/page").first?.rows.first)
        #expect(quicklinks.harness.universalActions(for: row).map(\.id) == ["open-link", "save-quicklink"])
    }

    @Test func withEverySearchOffOnlyTheAddressActionRemains() async throws {
        let only = Quicklink(id: "static", name: "Static", link: "https://static.example.com")
        let file = QuicklinkFile(quicklinks: [only], removedDefaults: DefaultSearches.all.map(\.id))
        let quicklinks = try await QuicklinksHarness(file: file)
        #expect(quicklinks.feature.defaultEngine == nil)
        #expect(quicklinks.harness.universalActions(for: .text("words")).isEmpty)
        #expect(quicklinks.harness.universalActions(for: .text("example.com")).map(\.id) == ["open-link"])
    }
}
