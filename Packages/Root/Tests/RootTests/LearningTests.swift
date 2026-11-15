import CoreBridge
import Foundation
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Testing

@testable import Root

@Suite struct LearningTests {
    @Test func aRunRecordsAUseAndANeverRowRecordsNothing() async throws {
        let fixture = await RootFixture.ready()
        let calendar = fixture.apps.id("Calendar")
        try await fixture.pick("Calendar", for: "cal")
        #expect(fixture.root.usage.useCount(of: calendar) == 1)
        let recent = fixture.root.usage.recentlyUsed(namespace: "app", limit: 5)
        #expect(recent.map(\.id) == [calendar])
        #expect(recent.first?.snapshot?.title == "Calendar")

        try await fixture.pick("42", for: "=21")
        #expect(fixture.root.usage.useCount(of: ItemID("count", "21")) == 0)
        #expect(fixture.root.row(for: ItemID("count", "21")) == nil)
        await fixture.shutdown()
    }

    @Test func picksReportTheSourceTheyWereReachedBy() async throws {
        let fixture = await RootFixture.ready()
        let root = fixture.root
        _ = root.begin()
        let typed = root.update(query: "cal")
        let calendar = try #require(typed.rows.first { $0.title == "Calendar" })
        #expect(root.executionSource(for: calendar, launch: .root).source == .typed)
        #expect(root.executionSource(for: calendar, launch: .root).query == "cal")
        #expect(root.executionSource(for: calendar, launch: .hotkey).source == .hotkey)
        #expect(root.executionSource(for: calendar, launch: .suggestion).source == .suggestion)
        let fallback = try #require(typed.sections.last?.rows.first)
        #expect(root.executionSource(for: fallback, launch: .fallback) == (.fallback, "cal", nil))
        _ = root.update(query: "")
        #expect(root.executionSource(for: calendar, launch: .root).source == .hotkey)
        root.end()
        #expect(root.executionSource(for: calendar, launch: .root).query.isEmpty)
        await fixture.shutdown()
    }

    @Test func pausedLearningRecordsNothing() async throws {
        let fixture = await RootFixture.ready()
        fixture.general[HostSettings.learningPaused] = true
        await fixture.settle()
        try await fixture.pick("Terminal", for: "term")
        try await fixture.pick("Terminal", for: "term")
        #expect(fixture.results("term").first == "Term")
        #expect(fixture.root.usage.useCount(of: fixture.apps.id("Terminal")) == 0)

        fixture.general[HostSettings.learningPaused] = false
        await fixture.settle()
        try await fixture.pick("Terminal", for: "term")
        try await fixture.pick("Terminal", for: "term")
        #expect(fixture.results("term").first == "Terminal")
        await fixture.shutdown()
    }

    @Test func aLiveProvidersRowIsRememberedAndJoinsTheCatalog() async throws {
        let fixture = await RootFixture.ready()
        #expect(fixture.results("groceries").isEmpty)
        try await fixture.pick("Groceries List", for: "note groceries")
        #expect(fixture.results("groceries") == ["Groceries List"])
        let note = try #require(fixture.root.row(for: ItemID("note", "groceries")))
        #expect(note.payload?.string == "groceries")
        #expect(note.titleHighlights.isEmpty)
        await fixture.shutdown()
    }

    @Test func aCatalogRowIsNotRememberedTwice() async throws {
        let fixture = await RootFixture.ready()
        try await fixture.pick("Example Book", for: "example")
        fixture.library.books.rows.removeAll { $0.title == "Example Book" }
        fixture.library.books.signal.send()
        await fixture.settle()
        // Deleted from its source, the book is gone: only live providers' rows are remembered.
        #expect(fixture.results("example book").isEmpty)
        await fixture.shutdown()
    }

    @Test func learnOnlyRowsAreLearnedButNotRemembered() async throws {
        let fixture = await RootFixture.ready()
        fixture.library.notes.memory = .learnOnly
        try await fixture.pick("Groceries List", for: "note groceries")
        #expect(fixture.root.usage.useCount(of: ItemID("note", "groceries")) == 1)
        #expect(fixture.root.usage.recentlyUsed(namespace: "note", limit: 1).first?.snapshot == nil)
        #expect(fixture.results("groceries").isEmpty)
        #expect(fixture.root.row(for: ItemID("note", "groceries")) == nil)
        await fixture.shutdown()
    }

    @Test func forgetErasesLearningUsesAndTheRememberedRow() async throws {
        let fixture = await RootFixture.ready()
        let terminal = fixture.apps.id("Terminal")
        try await fixture.pick("Terminal", for: "term")
        try await fixture.pick("Terminal", for: "term")
        try await fixture.pick("Groceries List", for: "note groceries")
        #expect(fixture.results("term").first == "Terminal")

        fixture.root.forget(terminal)
        fixture.root.forget(ItemID("note", "groceries"))
        await fixture.settle()
        #expect(fixture.results("term").first == "Term")
        #expect(fixture.root.usage.useCount(of: terminal) == 0)
        #expect(fixture.results("groceries").isEmpty)
        await fixture.shutdown()
    }

    @Test func usageForgetAlsoForgetsTheRememberedRow() async throws {
        let fixture = await RootFixture.ready()
        try await fixture.pick("Groceries List", for: "note groceries")
        #expect(fixture.results("groceries") == ["Groceries List"])
        fixture.root.usage.forget(ItemID("note", "groceries"))
        await fixture.settle()
        #expect(fixture.results("groceries").isEmpty)

        try await fixture.pick("Groceries List", for: "note groceries")
        fixture.root.usage.forgetAll(namespace: "note")
        await fixture.settle()
        #expect(fixture.results("groceries").isEmpty)
        await fixture.shutdown()
    }

    @Test func rememberedRowsWhoseItemIsGoneAreForgottenOnTheHourlyCheck() async throws {
        let fixture = await RootFixture.ready()
        try await fixture.pick("Groceries List", for: "note groceries")
        try await fixture.pick("Errands List", for: "note errands")
        #expect(fixture.results("errands") == ["Errands List"])
        fixture.library.notes.deleted = [ItemID("note", "errands")]
        fixture.clock.advance(by: .seconds(30 * 60))
        await fixture.settle()
        #expect(fixture.library.notes.checked.last?.count == 2)
        #expect(fixture.results("errands").isEmpty)
        #expect(fixture.results("groceries") == ["Groceries List"])
        await fixture.shutdown()
    }

    @Test func aRememberedRowLeavesWithItsFeature() async throws {
        let fixture = await RootFixture.ready()
        try await fixture.pick("Groceries List", for: "note groceries")
        await fixture.preferences.setEnabled(false, feature: LibraryFeature.manifest.id)
        await fixture.settle()
        #expect(fixture.results("groceries").isEmpty)
        #expect(fixture.root.row(for: ItemID("note", "groceries")) == nil)

        await fixture.preferences.setEnabled(true, feature: LibraryFeature.manifest.id)
        await fixture.settle()
        #expect(fixture.results("groceries") == ["Groceries List"])
        await fixture.shutdown()
    }
}
