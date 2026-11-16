import AppKit
import Foundation
import Host
import Kit
import KitTesting
import LauncherUI
import Testing

/// A list source that reads in the background, as Menu Items reads the front app's menus, and
/// says "Reading" until the read ends with a change signal.
@MainActor final class ReadingList: ListSource, BusySource {
    let changes: ChangeSignal? = ChangeSignal()
    var isReading = false
    var titles: [String] = []
    var isBusy: Bool { isReading }

    func load(_ request: ListRequest) async throws -> ListResult {
        let rows = titles.map { Row(id: ItemID("reading", $0), title: $0) }
        return ListResult(sections: [ListSection(rows: rows)], emptyState: EmptyState(title: "Reading Menus"))
    }

    func actions(for row: Row) -> [Action] { [] }

    /// Ends the read with what it found, and signals as Menu Items does.
    func finishRead(_ found: [String]) {
        titles = found
        isReading = false
        changes?.send()
    }
}

/// A detail source with work of its own between streams.
@MainActor final class ReadingDetail: DetailSource, BusySource {
    var isBusy = false

    func start() -> AsyncThrowingStream<DetailUpdate, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.replace(.markdown("Ready")))
            continuation.finish()
        }
    }

    func actions(for detail: Detail) -> [Action] { [] }
}

/// A page whose source says it is busy is not idle, so a scenario's idle wait waits for the work.
@Suite("Panel: a busy source", .serialized, .timeLimit(.minutes(1)))
@MainActor struct BusySourceTests {
    @Test(arguments: [false, true])
    func aListOrGridWhoseSourceReadsIsBusyUntilTheReadEnds(grid: Bool) async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = ReadingList()
        let page = fixture.open(
            grid ? .grid(GridPage(source, title: "Menus")) : .list(ListPage(source, title: "Menus")))
        #expect(await waitUntil { fixture.panel.isIdle })

        source.isReading = true
        #expect(page.isBusy)
        #expect(!fixture.panel.isIdle)

        source.finishRead(["Close Window"])
        #expect(await waitUntil { fixture.panel.isIdle && fixture.panel.shownTitles == ["Close Window"] })
    }

    @Test func aDetailWhoseSourceWorksIsBusy() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = ReadingDetail()
        let page = fixture.open(.detail(DetailPage(title: "Answer", source: source)))
        #expect(await waitUntil { fixture.panel.isIdle })
        source.isBusy = true
        #expect(page.isBusy)
        #expect(!fixture.panel.isIdle)
        source.isBusy = false
        #expect(fixture.panel.isIdle)
    }
}
