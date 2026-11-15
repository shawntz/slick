import Foundation
import Kit
import KitTesting
import Testing

/// How the harness loads pages: after background work, in pages, with a dropdown the source
/// replaces, with sections that hide while searching and rows ordered by rank hints.
@Suite("FeatureHarness: pages", .timeLimit(.minutes(1)))
struct HarnessPageTests {
    /// Records what other apps copy, in a background loop, and lists it newest first in pages of two.
    final class Recorder: Feature, ListSource {
        static let manifest = FeatureManifest(id: "recorder", name: "Recorder", icon: .glyph("R"))
        let changes: ChangeSignal? = ChangeSignal()
        private(set) var texts: [String] = []
        private var monitor: Task<Void, Never>?
        private let context: FeatureContext

        init(context: FeatureContext) {
            self.context = context
        }

        func activate() async {
            let entries = context.pasteboard.entries()
            monitor = Task { [weak self] in
                for await entry in entries {
                    self?.texts.insert(entry.plainText ?? "", at: 0)
                    self?.changes?.send()
                }
            }
        }

        func deactivate() async {
            monitor?.cancel()
        }

        var commands: [Command] {
            [Command(id: "list", title: "List") { _ in .push(.list(ListPage(self))) }]
        }

        let filtering = ListFiltering.custom(debounce: .zero)

        func load(_ request: ListRequest) async throws -> ListResult {
            let start = request.page.flatMap { Int($0.value) } ?? 0
            let matching = texts.filter { request.query.isEmpty || $0.contains(request.query) }
            let page = matching.dropFirst(start).prefix(2)
            let rows = page.map { Row(id: ItemID("recorder", $0), title: $0, titleHighlights: [0..<1]) }
            let more = start + 2 < matching.count ? ListPageToken(String(start + 2)) : nil
            return ListResult(sections: [ListSection("All", rows: rows)], nextPage: more)
        }

        func actions(for row: Row) -> [Action] {
            [
                Action("Forget", id: "forget") { _ in
                    self.texts.removeAll { $0 == row.title }
                    self.changes?.send()
                    return .keepOpen
                },
                Action("Search", id: "search") { context in
                    context.setQuery("b")
                    return .keepOpen
                },
            ]
        }
    }

    /// A host-filtered list with a Recent section, rank hints and tags the source adds while open.
    final class Shelf: Feature, ListSource {
        static let manifest = FeatureManifest(id: "shelf", name: "Shelf", icon: .glyph("S"))
        var tags = ["red"]
        init(context: FeatureContext) {}

        var commands: [Command] {
            [Command(id: "open", title: "Open") { _ in .push(.list(ListPage(self))) }]
        }

        func load(_ request: ListRequest) async throws -> ListResult {
            let apple = Row(id: ItemID("shelf", "apple"), title: "Apple")
            let pie = Row(id: ItemID("shelf", "pie"), title: "Apple Pie", rankHint: 2)
            let options = tags.map { FilterOption(id: $0, title: $0) }
            return ListResult(
                sections: [
                    ListSection("Recent", id: "recent", visibility: .whenQueryEmpty, rows: [pie]),
                    ListSection("All", rows: [apple, pie]),
                ],
                filter: FilterDropdown(title: "Tag", options: options))
        }

        func actions(for row: Row) -> [Action] { [] }
    }

    @Test func settleWaitsForTheMonitorAndReloadsTheOpenPage() async throws {
        let harness = FeatureHarness(Recorder.self)
        await harness.activate()
        try await harness.run("list")
        harness.fakes.pasteboard.simulateCopy("alpha")
        harness.fakes.pasteboard.simulateCopy("beta")
        try await harness.settle()
        #expect(harness.rows.map(\.title) == ["beta", "alpha"])
        await harness.deactivate()
        harness.fakes.pasteboard.simulateCopy("gamma")
        try await harness.settle()
        #expect(harness.rows.map(\.title) == ["beta", "alpha"], "a stopped monitor records nothing")
    }

    @Test func waitForChangeReloadsWhenTheSourceSignals() async throws {
        let harness = FeatureHarness(Recorder.self)
        await harness.activate()
        try await harness.run("list")
        harness.fakes.pasteboard.simulateCopy("alpha")
        try await harness.waitForChange()
        #expect(harness.rows.map(\.title) == ["alpha"])
    }

    @Test func anActionThatSignalsReloadsOnce() async throws {
        let harness = FeatureHarness(Recorder.self)
        await harness.activate()
        harness.fakes.pasteboard.simulateCopy("alpha")
        harness.fakes.pasteboard.simulateCopy("beta")
        try await harness.settle()
        try await harness.run("list")
        try await harness.perform("forget")
        #expect(harness.rows.map(\.title) == ["alpha"])
        try await harness.perform("search")
        #expect(harness.rows.isEmpty, "a query set by an action loads like typing")
    }

    @Test func pagedResultsAppendToTheirSection() async throws {
        let harness = FeatureHarness(Recorder.self)
        await harness.activate()
        for text in ["e", "d", "c", "b", "a"] { harness.fakes.pasteboard.simulateCopy(text) }
        try await harness.settle()
        try await harness.run("list")
        #expect(harness.rows.map(\.title) == ["a", "b"])
        #expect(try await harness.loadNextPage())
        #expect(try await harness.loadNextPage())
        #expect(try await harness.loadNextPage() == false)
        #expect(harness.sections.map(\.title) == ["All"])
        #expect(harness.rows.map(\.title) == ["a", "b", "c", "d", "e"])
        #expect(harness.rows.first?.titleHighlights == [0..<1])
    }

    @Test func recentSectionsHideWhileSearchingAndHintsOrderATier() async throws {
        let harness = FeatureHarness(Shelf.self)
        try await harness.run("open")
        #expect(harness.sections.map(\.title) == ["Recent", "All"])
        try harness.select(at: 2)
        #expect(harness.page?.selectedSection == "All", "one row in two sections is selected by section")
        try await harness.setQuery("app")
        #expect(harness.sections.map(\.title) == ["All"])
        #expect(harness.rows.map(\.title) == ["Apple Pie", "Apple"], "the hint wins inside the prefix tier")
        try await harness.setQuery("apple")
        #expect(harness.rows.map(\.title) == ["Apple", "Apple Pie"], "a stronger tier wins over any hint")
    }

    @Test func aDropdownFromTheSourceReplacesThePagesAndFallsBack() async throws {
        let harness = FeatureHarness(Shelf.self)
        try await harness.run("open")
        #expect(harness.page?.filter == "red")
        try await harness.setFilter("red")
        harness.feature.tags = ["blue", "green"]
        try await harness.reloadPage()
        #expect(harness.page?.dropdown?.options.map(\.id) == ["blue", "green"])
        #expect(harness.page?.filter == "blue", "a filter no longer offered falls back to the default")
    }
}
