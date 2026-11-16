import AppKit
import Foundation
import Host
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import Testing

/// Kit's `PageEvents`: a page's source hears that the panel closed and that its page shows again,
/// and a detail stream runs on while the panel is closed.
@Suite("Panel: page events", .serialized, .timeLimit(.minutes(1)))
@MainActor struct PageEventsTests {
    private func hide(_ fixture: PanelFixture) {
        fixture.panel.summoner.dismiss(returnFocus: false)
    }

    /// Gives tasks that should not run a chance to run, without waiting on the clock.
    private func letTasksRun() async {
        for _ in 0..<50 { await Task.yield() }
    }

    private func openList(_ fixture: PanelFixture, _ source: EventfulList) async -> ListPageController? {
        guard let page = fixture.open(.list(ListPage(source, title: source.name))) as? ListPageController,
            await waitUntil({ page.loadCount == 1 })
        else { return nil }
        return page
    }

    @Test func theSourceHearsTheCloseAndTheOpenAndItsSignalThereCostsOneLoad() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let log = EventLog()
        let source = EventfulList("Menus", log: log)
        source.sendsOnShow = true
        let page = try #require(await openList(fixture, source))
        #expect(log.entries.isEmpty, "the first push is not a show again")

        hide(fixture)
        #expect(log.entries == ["Menus closed"])
        await letTasksRun()
        #expect(page.loadCount == 1, "nothing loads while the panel is hidden")

        fixture.panel.summon()
        #expect(await waitUntil { page.loadCount == 2 })
        await letTasksRun()
        #expect(log.entries == ["Menus closed", "Menus opened"])
        #expect(page.loadReasons == [.open, .reload], "the signal sent on show reloads once")
    }

    @Test func everyPageInTheStackHearsTheCloseTopFirst() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let log = EventLog()
        _ = try #require(await openList(fixture, EventfulList("Below", log: log)))
        _ = try #require(await openList(fixture, EventfulList("Above", log: log)))
        hide(fixture)
        #expect(log.entries == ["Above closed", "Below closed"])
    }

    @Test func goingBackTellsTheSourceAndItsSignalThereCostsOneLoad() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let log = EventLog()
        let below = EventfulList("Below", log: log)
        below.sendsOnShow = true
        let page = try #require(await openList(fixture, below))
        _ = try #require(await openList(fixture, EventfulList("Above", log: log)))
        fixture.panel.pop()
        #expect(log.entries == ["Below returned"])
        #expect(await waitUntil { page.loadCount == 2 })
        await letTasksRun()
        #expect(page.loadReasons == [.open, .reload])
    }

    @Test func aPopWhileHiddenWaitsForTheNextShow() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let log = EventLog()
        let below = EventfulList("Below", log: log)
        below.sendsOnShow = true
        let page = try #require(await openList(fixture, below))
        _ = try #require(await openList(fixture, EventfulList("Above", log: log)))
        hide(fixture)
        fixture.panel.pop()
        await letTasksRun()
        #expect(log.entries == ["Above closed", "Below closed"], "a pop while hidden is not a show")
        #expect(page.loadCount == 1)

        fixture.panel.summon()
        #expect(await waitUntil { page.loadCount == 2 })
        #expect(log.entries.last == "Below opened")
    }

    @Test func aDetailStreamRunsOnWhileHiddenAndDrawsOnceShown() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = Streamer()
        let page = try #require(
            fixture.open(.detail(DetailPage(title: "Answer", source: source))) as? DetailPageController)
        source.current?.yield(.replace(.markdown("First.")))
        #expect(await waitUntil { page.pane.bodyText == "First." })
        let drawn = page.draws

        hide(fixture)
        #expect(source.events == ["closed"])
        source.current?.yield(.append(" Second."))
        #expect(await waitUntil { page.detail == .markdown("First. Second.") }, "the model keeps filling")
        await letTasksRun()
        #expect(page.draws == drawn, "nothing draws while hidden")
        #expect(page.isStreaming)
        #expect(source.cancelledStreams == 0, "a hide is not a stop")

        fixture.panel.summon()
        #expect(await waitUntil { page.pane.bodyText == "First. Second." })
        #expect(source.events == ["closed", "opened"])
        #expect(source.cancelledStreams == 0)
        source.current?.finish()
        #expect(await waitUntil { !page.isStreaming })
        #expect(source.cancelledStreams == 0)
    }

    @Test func aDetailSourceHearsWhenTheUserGoesBackToIt() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = Streamer()
        _ = try #require(fixture.open(.detail(DetailPage(title: "Answer", source: source))) as? DetailPageController)
        _ = try #require(await openList(fixture, EventfulList("Above", log: EventLog())))
        fixture.panel.pop()
        #expect(source.events == ["returned"])
    }

    // MARK: Return in an empty follow-up field

    @Test func returnInAnEmptyFollowUpFieldNeverStopsAStreamingAnswer() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = StoppableAnswer()
        let page = try #require(
            fixture.open(.detail(DetailPage(title: "Answer", source: source))) as? DetailPageController)
        #expect(page.isStreaming)
        #expect(await waitUntil { page.actions.map(\.title) == ["Stop"] })
        #expect(
            fixture.panel.surface.actionBar.content.primaryTitle == nil, "Return does not stop, so the bar says nothing"
        )

        fixture.press(.submit([]))
        await letTasksRun()
        #expect(source.stops == 0)
        #expect(source.followUps.isEmpty)

        fixture.command(".")
        #expect(await waitUntil { source.stops == 1 }, "Stop keeps its own shortcut")
    }

    @Test func returnInAnEmptyFollowUpFieldRunsThePrimaryActionOnceTheAnswerEnds() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = StoppableAnswer()
        let page = try #require(
            fixture.open(.detail(DetailPage(title: "Answer", source: source))) as? DetailPageController)
        source.finish()
        #expect(await waitUntil { !page.isStreaming })
        #expect(await waitUntil { fixture.panel.surface.actionBar.content.primaryTitle == "Copy Answer" })

        fixture.press(.submit([]))
        #expect(await waitUntil { source.copies == 1 })
        #expect(source.followUps.isEmpty)

        fixture.type("and then")
        fixture.press(.submit([]))
        #expect(source.followUps == ["and then"], "typed text is a follow-up")
        #expect(source.copies == 1)
    }
}

/// Page events in the order they arrived, across sources.
@MainActor final class EventLog {
    private(set) var entries: [String] = []

    func add(_ entry: String) {
        entries.append(entry)
    }
}

/// A host-filtered list whose source hears page events, as a list of another app's menus does.
@MainActor final class EventfulList: ListSource, PageEvents {
    let changes: ChangeSignal? = ChangeSignal()
    let name: String
    let log: EventLog
    /// Sends the change signal when the page shows again, to read its data again.
    var sendsOnShow = false

    init(_ name: String, log: EventLog) {
        self.name = name
        self.log = log
    }

    func load(_ request: ListRequest) async throws -> ListResult {
        ListResult(sections: [ListSection(name, id: "rows", rows: [Row(id: ItemID("events", name), title: name)])])
    }

    func actions(for row: Row) -> [Action] { [] }

    func pageWillShowAgain(_ reason: PageShowReason) {
        log.add(name + (reason == .panelOpened ? " opened" : " returned"))
        if sendsOnShow { changes?.send() }
    }

    func panelDidClose() {
        log.add(name + " closed")
    }
}

/// An answer that offers Stop while it streams and Copy Answer after, as the AI feature does.
@MainActor final class StoppableAnswer: DetailSource {
    typealias Stream = AsyncThrowingStream<DetailUpdate, any Error>

    let actionsChanged: ChangeSignal? = ChangeSignal()
    let followUp: FollowUp? = FollowUp(placeholder: "Ask a follow-up")
    private(set) var stops = 0
    private(set) var copies = 0
    private(set) var followUps: [String] = []
    private var streaming = false
    private var continuation: Stream.Continuation?

    func start() -> Stream {
        makeStream()
    }

    func followUp(_ text: String) -> Stream {
        followUps.append(text)
        return makeStream()
    }

    func finish() {
        streaming = false
        continuation?.finish()
    }

    func actions(for detail: Detail) -> [Action] {
        if streaming {
            return [
                Action("Stop", id: "stop", shortcut: KeyCombo(.period, .command), runPolicy: .concurrent) { _ in
                    self.stops += 1
                    return .keepOpen
                }
            ]
        }
        return [
            Action("Copy Answer", id: "copy") { _ in
                self.copies += 1
                return .keepOpen
            }
        ]
    }

    private func makeStream() -> Stream {
        let (stream, continuation) = Stream.makeStream()
        self.continuation = continuation
        streaming = true
        actionsChanged?.send()
        return stream
    }
}
