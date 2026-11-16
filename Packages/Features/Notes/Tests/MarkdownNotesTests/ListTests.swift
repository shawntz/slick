import Foundation
import Kit
import KitTesting
import Testing

@testable import MarkdownNotes

@Suite("Search Notes", .timeLimit(.minutes(1)))
struct ListTests {
    /// Four notes: one changed an hour ago, one yesterday, one three days ago, one ten days ago.
    static func dated() async throws -> FeatureHarness<NotesFeature> {
        let fakes = FakeServices()
        let clock = fakes.clock
        let harness = try await FeatureHarness.make(fakes: fakes)
        try harness.write("Groceries.md", Sample.groceries, modified: daysAgo(0, hours: 1, clock: clock))
        try harness.write("Budget 2027.md", Sample.budget, modified: daysAgo(1, clock: clock))
        try harness.write("Trip ideas.md", Sample.trip, modified: daysAgo(3, clock: clock))
        try harness.write("Weekly sync.md", Sample.meeting, modified: daysAgo(10, clock: clock))
        try await harness.openSearch()
        return harness
    }

    @Test func pinnedNotesComeFirstThenADayEach() async throws {
        let harness = try await Self.dated()
        let days = DaySections(clock: harness.fakes.clock, direction: .past)
        let clock = harness.fakes.clock
        #expect(
            harness.sectionTitles == [
                "Today", "Yesterday", days.title(for: daysAgo(3, clock: clock)),
                days.title(for: daysAgo(10, clock: clock)),
            ])
        #expect(harness.rows.map(\.title) == ["Groceries", "Budget 2027", "Trip ideas", "Weekly sync"])
        #expect(harness.rows.first?.subtitle == "Milk and eggs")
        #expect(harness.rows.first?.accessories.first == .tag("#errands"))

        try harness.select(title: "Trip ideas")
        try await harness.perform("pin")
        #expect(harness.toasts.last?.title == "Pinned Note")
        #expect(harness.sectionTitles.first == "Pinned")
        #expect(harness.sections.first?.rows.map(\.title) == ["Trip ideas"])
        #expect(!harness.sections.dropFirst().flatMap(\.rows).contains { $0.title == "Trip ideas" })
        #expect(harness.issues.isEmpty)
    }

    @Test func titleMatchesComeFirstWithHighlightsAndTextMatchesShowWhere() async throws {
        let harness = try await Self.dated()
        try await harness.setQuery("budget")
        #expect(harness.sectionTitles == ["Matching Titles", "Matching Text"])
        #expect(harness.rows.map(\.title) == ["Budget 2027", "Trip ideas"])
        #expect(harness.rows[0].titleHighlights == [0..<6])
        #expect(harness.rows[1].subtitle == "Visit the coast and plan the budget for the ferry.")

        // Every word must match, in the title or the text, whatever the case or accents.
        try await harness.setQuery("TRIP coast")
        #expect(harness.rows.map(\.title) == ["Trip ideas"])
        #expect(harness.rows[0].titleHighlights == [0..<4])
        try await harness.setQuery("cafe")
        #expect(harness.rows.map(\.title) == ["Weekly sync"])
        try await harness.setQuery("errands")
        #expect(harness.rows.map(\.title) == ["Groceries"])

        // A pinned match comes first.
        try await harness.setQuery("")
        try harness.select(title: "Trip ideas")
        try await harness.perform("pin")
        try await harness.setQuery("budget")
        #expect(harness.sectionTitles == ["Pinned", "Matching Titles"])
        #expect(harness.rows.map(\.title) == ["Trip ideas", "Budget 2027"])

        try await harness.setQuery("zebra")
        #expect(harness.rows.isEmpty)
        #expect(harness.page?.emptyState?.title == "No Matching Notes")
        try await harness.perform("create")
        #expect(harness.page?.formValues.text("body") == "zebra")
    }

    @Test func theDetailRendersTheNoteAndSaysWhatItIs() async throws {
        let harness = try await Self.dated()
        try harness.select(title: "Weekly sync")
        let detail = try #require(try await harness.loadDetail())
        #expect(detail.body == .markdown(Sample.meeting))
        #expect(
            detail.metadata == [
                .tags("Tags", [Tag("#work", color: .accent), Tag("#team", color: .accent)]),
                .date("Modified", daysAgo(10, clock: harness.fakes.clock)),
                .label("Words", value: "12"),
                .label("File", value: "Weekly sync.md"),
            ])
    }

    @Test func returnEditsAndCommandReturnOpensTheEditor() async throws {
        let harness = try await Self.dated()
        #expect(
            try harness.actionIDs(of: "Groceries") == [
                "edit", "open", "copy-markdown", "copy-plain-text", "paste", "pin", "rename", "duplicate", "reveal",
                "move-to-trash", "run.cmd:notes.create",
            ])
        let actions = harness.actions()
        #expect(actions.secondary?.id == "open")
        #expect(Set(actions.compactMap(\.shortcut)).count == actions.compactMap(\.shortcut).count)

        try await harness.performPrimary()
        #expect(harness.page?.formValues.text("title") == "Groceries")
        #expect(harness.page?.formValues.text("body") == "Milk and eggs")
        #expect(harness.page?.formValues.strings("tags") == ["errands"])
        harness.pop()

        try harness.select(title: "Groceries")
        try await harness.performSecondary()
        #expect(harness.fakes.workspace.opened == [harness.defaultFolder.appending(path: "Groceries.md")])
        #expect(harness.isClosed)
        #expect(harness.issues.isEmpty)
    }

    @Test func anEmptyFolderOffersToCreateANote() async throws {
        let harness = try await FeatureHarness.make()
        try await harness.openSearch()
        #expect(harness.rows.isEmpty)
        #expect(harness.page?.emptyState?.title == "No Notes Yet")
        #expect(harness.page?.notice == nil)
        try await harness.perform("create")
        #expect(harness.page?.formValues.text("body") == "")
    }
}
