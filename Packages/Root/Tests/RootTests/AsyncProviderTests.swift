import CoreBridge
import Foundation
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Testing

@testable import Root

/// Async providers through root search: debounce, cancellation, limits, takeover, titles, order,
/// loading and failure.
@Suite(.timeLimit(.minutes(1))) struct AsyncProviderTests {
    @Test func eachProviderWaitsForItsOwnDebounceAndOnlyTheLastQueryRuns() async throws {
        let fixture = await RootFixture.ready(signals: true)
        let signals = try fixture.signalsFeature()
        let root = fixture.root
        _ = root.begin()
        _ = root.update(query: "ab")
        _ = root.update(query: "abc")
        _ = root.update(query: "abcd")
        for _ in 0..<50 { await Task.yield() }
        // Mail has no debounce and runs as soon as the keystrokes stop; the web waits 60 ms of quiet.
        // The keystrokes came faster than either could start, so only the last query ran.
        #expect(signals.mail.calls == ["abcd"])
        #expect(signals.web.calls.isEmpty)
        await fixture.passDebounce()
        #expect(signals.web.calls == ["abcd"])

        // Typing on after the mail answered runs it again for the new query only.
        _ = root.update(query: "abcde")
        for _ in 0..<50 { await Task.yield() }
        #expect(signals.mail.calls == ["abcd", "abcde"])
        #expect(signals.web.calls == ["abcd"])
        root.end()
        await fixture.shutdown()
    }

    @Test func shortQueriesAreNotSentAndRowsAreCappedUnlessTheProviderTakesOver() async throws {
        let fixture = await RootFixture.ready(signals: true)
        let signals = try fixture.signalsFeature()
        let root = fixture.root
        _ = root.begin()
        _ = root.update(query: "a")
        await fixture.passDebounce()
        #expect(signals.web.calls.isEmpty)
        #expect(signals.mail.calls.isEmpty)

        signals.web.answers["zq"] = (1...5).map { Row(id: ItemID("web", "\($0)"), title: "Page \($0)") }
        _ = root.update(query: "zq")
        await fixture.passDebounce()
        #expect(signals.mail.calls.isEmpty)
        let web = try #require(root.snapshot.sections.first { $0.id == "async.web" })
        #expect(web.rows.map(\.title) == ["Page 1", "Page 2", "Page 3"])
        #expect(web.title == "Web")

        signals.mail.rowCount = 7
        let takeover = root.update(query: "@team")
        #expect(takeover.sections.isEmpty)
        #expect(takeover.isLoading)
        #expect(takeover.emptyState == nil)
        await fixture.passDebounce()
        let only = root.snapshot
        #expect(only.sections.map(\.id) == ["async.mail"])
        #expect(only.sections.first?.title == "Mail matching @team")
        #expect(only.rows.count == 7)
        #expect(!only.isLoading)
        root.end()
        await fixture.shutdown()
    }

    @Test func lateSectionsAppendInOrderWithoutMovingWhatIsAbove() async throws {
        let fixture = await RootFixture.ready(signals: true)
        let root = fixture.root
        _ = root.begin()
        let typed = root.update(query: "term")
        let above = typed.sections.filter { $0.kind != .fallbacks }
        #expect(above.first?.kind == .results)
        #expect(typed.isLoading)

        // Mail arrives first, then the web, which is earlier in display order.
        for _ in 0..<50 { await Task.yield() }
        let afterMail = root.snapshot
        #expect(afterMail.sections.map(\.id).suffix(2) == ["async.mail", "fallbacks"])
        #expect(afterMail.isLoading)
        await fixture.passDebounce()
        let done = root.snapshot
        // The file provider found nothing, so it adds no section.
        #expect(done.sections.map(\.id).suffix(3) == ["async.web", "async.mail", "fallbacks"])
        #expect(!done.isLoading)
        // Everything that showed at the keystroke is still on top, row for row.
        #expect(Array(done.sections.prefix(above.count)) == above)
        #expect(done.revision > afterMail.revision)
        root.end()
        await fixture.shutdown()
    }

    @Test func anItemThatAlreadyShowsIsNotRepeatedInALateSection() async throws {
        let fixture = await RootFixture.ready(signals: true)
        let signals = try fixture.signalsFeature()
        let root = fixture.root
        let calendar = try #require(root.row(for: fixture.apps.id("Calendar")))
        signals.web.answers["calendar"] = [calendar, Row(id: ItemID("web", "cal"), title: "Calendar Help")]
        _ = root.begin()
        _ = root.update(query: "calendar")
        await fixture.passDebounce()
        #expect(root.snapshot.rows.filter { $0.id == calendar.id }.count == 1)
        #expect(root.snapshot.section(containing: calendar.id)?.kind == .results)
        #expect(root.snapshot.sections.first { $0.id == "async.web" }?.rows.map(\.title) == ["Calendar Help"])
        root.end()
        await fixture.shutdown()
    }

    @Test func aChangedQueryCancelsTheOldWorkAndDropsItsLateResult() async throws {
        let fixture = await RootFixture.ready(signals: true)
        let signals = try fixture.signalsFeature()
        let root = fixture.root
        signals.web.hold = true
        _ = root.begin()
        _ = root.update(query: "garden")
        for _ in 0..<50 { await Task.yield() }
        fixture.clock.advance(by: .milliseconds(60))
        for _ in 0..<50 { await Task.yield() }
        #expect(signals.web.heldCount == 1)

        _ = root.update(query: "gardens")
        signals.web.hold = false
        signals.web.release()
        for _ in 0..<50 { await Task.yield() }
        // The held call for "garden" ended after the query changed: its rows never show.
        #expect(!root.snapshot.sections.contains { $0.id == "async.web" })
        #expect(signals.web.calls == ["garden"])

        await fixture.passDebounce()
        #expect(root.snapshot.sections.first { $0.id == "async.web" }?.rows.map(\.title) == ["Web: gardens"])
        root.end()
        await fixture.shutdown()
    }

    @Test func endingTheSessionStopsTheProviders() async throws {
        let fixture = await RootFixture.ready(signals: true)
        let signals = try fixture.signalsFeature()
        let root = fixture.root
        _ = root.begin()
        _ = root.update(query: "garden")
        root.end()
        let changes = root.changes.generation
        for _ in 0..<50 { await Task.yield() }
        fixture.clock.advance(by: .milliseconds(100))
        for _ in 0..<50 { await Task.yield() }
        #expect(signals.web.calls.isEmpty)
        #expect(root.changes.generation == changes)
        #expect(root.providerTasks.isEmpty)
        await fixture.shutdown()
    }

    @Test func aProviderThatThrowsLeavesItsSectionEmptyAndTheOthersFill() async throws {
        let fixture = await RootFixture.ready(signals: true)
        let signals = try fixture.signalsFeature()
        let root = fixture.root
        signals.web.failure = ExampleFailure()
        _ = root.begin()
        _ = root.update(query: "zzqqxx")
        await fixture.passDebounce()
        let snapshot = root.snapshot
        #expect(!snapshot.sections.contains { $0.id == "async.web" })
        #expect(snapshot.sections.contains { $0.id == "async.mail" })
        #expect(!snapshot.isLoading)
        root.end()
        await fixture.shutdown()
    }

    /// A file search that finds an app's bundle stands for the same file as the app row above it, so
    /// the app shows once and the section keeps only the other files.
    @Test func aLateRowForAFileAnotherRowStandsForIsLeftOut() async throws {
        let bundle = URL(filePath: "/Example Apps/Editor.app/")
        let apps = ExampleApps()
        apps.rows = apps.rows.map { row in
            var row = row
            if row.title == "Editor" { row.represents = .files([URL(filePath: "/Example Apps/Editor.app")]) }
            return row
        }
        let fixture = await RootFixture.ready(apps: apps, signals: true)
        let signals = try fixture.signalsFeature()
        let root = fixture.root
        signals.web.answers["editor"] = [
            Row(id: ItemID("web", "bundle"), title: "Editor.app", represents: .files([bundle])),
            Row(id: ItemID("web", "notes"), title: "Editor notes.txt", represents: .files([URL(filePath: "/n.txt")])),
        ]
        _ = root.begin()
        let typed = root.update(query: "editor")
        #expect(typed.rows.first?.id == apps.id("Editor"))
        await fixture.passDebounce()
        let late = try #require(root.snapshot.sections.first { $0.id == "async.web" })
        #expect(late.rows.map(\.title) == ["Editor notes.txt"])
        #expect(root.snapshot.rows.filter { $0.title.hasPrefix("Editor") }.count == 2)
        root.end()
        await fixture.shutdown()
    }

    @Test func aRunFromALateSectionTeachesTheQueryAndIsRemembered() async throws {
        let fixture = await RootFixture.ready(signals: true)
        let root = fixture.root
        _ = root.begin()
        _ = root.update(query: "zzqqxx")
        await fixture.passDebounce()
        let page = try #require(root.snapshot.sections.first { $0.id == "async.web" }?.rows.first)
        #expect(root.executionSource(for: page, launch: .root).source == .typed)
        #expect(root.actions(for: page).map(\.title) == ["Open Page"])
        #expect(root.featureID(for: page) == "signals")
        root.didRun(page, launch: .root)
        root.end()
        await fixture.settle()
        #expect(fixture.results("web: zzq").first == "Web: zzqqxx")
        await fixture.shutdown()
    }
}
