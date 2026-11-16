import AppKit
import Foundation
import Host
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import Testing

/// A list whose rows stand for text, one of them with its own Command-L action.
@MainActor final class CodeList: ListSource {
    func load(_ request: ListRequest) async throws -> ListResult {
        ListResult(rows: [
            Row(id: ItemID("codes", "door"), title: "Door Code", represents: .text("482 913")),
            Row(id: ItemID("codes", "own"), title: "Own Shortcut", represents: .text("555 0100")),
            Row(id: ItemID("codes", "file"), title: "A File", represents: .files([URL(filePath: "/tmp/example.txt")])),
        ])
    }

    private(set) var ownRuns = 0

    func actions(for row: Row) -> [Action] {
        guard row.id.key == "own" else { return [Action("Copy", id: "copy") { _ in .keepOpen }] }
        return [
            Action("Copy", id: "copy") { _ in .keepOpen },
            Action("Lock", id: "lock", shortcut: .largeType) { _ in
                self.ownRuns += 1
                return .keepOpen
            },
        ]
    }
}

/// Show in Large Type, the host's action for every row and detail that stands for text: Command-L,
/// its place in the action panel, the outcome a feature returns, and the record a scenario reads.
/// Outside the live launcher the text is recorded, never shown.
@Suite("Panel: Large Type", .serialized, .timeLimit(.minutes(1)))
@MainActor struct LargeTypeHostTests {
    private func recorded(_ fixture: PanelFixture) -> [String] {
        (fixture.panel.largeType as? RecordingLargeType)?.shown ?? ["not recorded"]
    }

    @Test func outsideTheLiveLauncherLargeTypeIsRecorded() async {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        #expect(fixture.panel.largeType is RecordingLargeType)
    }

    @Test func commandLOnARootRowThatStandsForTextClosesThePanelAndShowsIt() async {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.type("notes")
        #expect(fixture.panel.rootPage.selectedRow?.row.title == "Notes")
        #expect(fixture.command("l"))
        #expect(!fixture.panel.isPanelVisible)
        #expect(recorded(fixture) == ["notes"])
        #expect(fixture.panel.lastLargeType == "notes")
    }

    @Test func aRowThatStandsForNoTextHasNoLargeType() async {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.type("example editor")
        #expect(fixture.panel.rootPage.selectedRow?.row.title == "Example Editor")
        #expect(!fixture.command("l"))
        fixture.command("k")
        #expect(!fixture.panel.actionEntries.map(\.title).contains("Show in Large Type"))
        #expect(recorded(fixture).isEmpty)
    }

    @Test func theActionPanelListsItAfterTheRowsOwnEntriesWithItsKey() async {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.type("notes")
        fixture.command("k")
        let titles = fixture.panel.actionEntries.map(\.title)
        #expect(titles.starts(with: ["Open", "Copy", "Reveal", "Show in Large Type"]), "\(titles)")
        let entry = fixture.panel.actionEntries.first { $0.title == "Show in Large Type" }
        #expect(entry?.shortcut == .largeType)
        let index = String(titles.firstIndex(of: "Show in Large Type") ?? 0)
        fixture.panel.actionCard.onActivate?(ActionItem(id: index, title: "Show in Large Type"))
        #expect(recorded(fixture) == ["notes"])
        #expect(!fixture.panel.isPanelVisible)
    }

    @Test func aPushedListsRowsGetItAndARowsOwnCommandLWins() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = CodeList()
        let page = try #require(fixture.open(.list(ListPage(source, title: "Codes"))) as? ListPageController)
        #expect(await waitUntil { page.loadCount == 1 })

        fixture.press(.moveDown)
        #expect(page.selectedRow?.title == "Own Shortcut")
        fixture.command("l")
        #expect(await waitUntil { source.ownRuns == 1 }, "the row's own Command-L action runs")
        #expect(recorded(fixture).isEmpty)
        fixture.command("k")
        let entry = fixture.panel.actionEntries.first { $0.title == "Show in Large Type" }
        #expect(entry != nil && entry?.shortcut == nil, "listed without the key its row took")
        fixture.command("k")

        fixture.press(.moveDown)
        #expect(page.selectedRow?.title == "A File")
        #expect(!fixture.command("l"), "a row that stands for files has none")

        fixture.press(.moveUp)
        fixture.press(.moveUp)
        #expect(page.selectedRow?.title == "Door Code")
        fixture.command("l")
        #expect(recorded(fixture) == ["482 913"])
    }

    @Test func aDetailThatStandsForTextGetsItEvenWithoutActionsOfItsOwn() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        _ = fixture.open(
            .detail(DetailPage(title: "Contact", detail: Detail(.text("555 0100"), represents: .text("555 0100")))))
        #expect(await waitUntil { fixture.panel.top.target != nil })
        fixture.command("k")
        #expect(fixture.panel.actionEntries.map(\.title).first == "Show in Large Type")
        fixture.command("k")
        fixture.command("l")
        #expect(recorded(fixture) == ["555 0100"])
    }

    @Test func aFeatureReturnsItAsAnOutcome() async {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let action = Action.showInLargeType("  482 913\n")
        await fixture.panel.runtime.pipeline.perform(
            action, featureID: "workbench", context: fixture.runtime.runtime.context(for: "workbench"), query: "",
            launch: .page, row: nil
        ).value
        #expect(!fixture.panel.isPanelVisible, "the panel closes first")
        #expect(recorded(fixture) == ["482 913"])
    }

    @Test func aRunFromAnEndedSessionStillShowsItWhileThePanelIsClosed() async {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let panel = fixture.panel
        let origin = { () -> RunOrigin in
            var origin = fixture.workbenchOrigin
            origin.session = panel.sessionID
            return origin
        }()
        panel.dismiss()
        panel.apply(.showLargeType("482 913"), origin: origin)
        #expect(recorded(fixture) == ["482 913"])

        // The user opened the panel again: a late result does not close it.
        panel.summon()
        panel.apply(.showLargeType("555 0100"), origin: origin)
        #expect(panel.isPanelVisible)
        #expect(recorded(fixture) == ["482 913"])
    }
}
