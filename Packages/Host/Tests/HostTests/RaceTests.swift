import AppKit
import Foundation
import Host
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import Testing

/// Races against the pipeline and the pages: what happens when things overlap.
@Suite("Races", .serialized, .timeLimit(.minutes(1)))
@MainActor struct RaceTests {
    // MARK: Hotkeys under each policy

    private func bindAndPressTwice(_ fixture: RuntimeFixture, _ command: String) async throws {
        let id = RuntimeFixture.command(command)
        try fixture.runtime.preferences.setHotkey(KeyCombo(.j, [.option, .command]), for: id)
        let binding = HostPreferences.bindingID(for: id)
        async let first = fixture.fakes.hotkeys.press(binding)
        async let second = fixture.fakes.hotkeys.press(binding)
        let pressed = await (first, second)
        #expect(pressed == (true, true))
    }

    @Test func twoSerialHotkeysRunOneAfterTheOther() async throws {
        let fixture = RuntimeFixture()
        await fixture.start()
        try await bindAndPressTwice(fixture, "slow")
        let clock = fixture.fakes.clock
        await clock.waitForSleepers(1)
        #expect(clock.sleeperCount == 1, "the second run waits for the first")
        clock.advance(by: .seconds(1))
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(1))
        #expect(await waitUntil { fixture.workbench.presses == [0, 1] })
    }

    @Test func twoDropWhileRunningHotkeysRunOnce() async throws {
        let fixture = RuntimeFixture()
        await fixture.start()
        try await bindAndPressTwice(fixture, "once")
        await fixture.fakes.clock.waitForSleepers(1)
        #expect(await waitUntil { fixture.runtime.pipeline.droppedRuns == ["workbench/command.once"] })
        fixture.fakes.clock.advance(by: .seconds(1))
        #expect(await waitUntil { fixture.runtime.pipeline.runningHandlerCount == 0 })
    }

    @Test func twoConcurrentHotkeysRunTogether() async throws {
        let fixture = RuntimeFixture()
        await fixture.start()
        try await bindAndPressTwice(fixture, "wait")
        await fixture.fakes.clock.waitForSleepers(2)
        #expect(fixture.workbench.log == ["wait started", "wait started"])
        fixture.fakes.clock.advance(by: .seconds(600))
        #expect(await waitUntil { fixture.workbench.log.count == 4 })
    }

    // MARK: Outcomes after the panel moved on

    @Test func anOutcomeAfterThePanelClosedDoesNotReopenIt() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let clock = fixture.runtime.fakes.clock
        let push = fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("late-push"), launch: .root)
        let close = fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("late-close"), launch: .root)
        await clock.waitForSleepers(2)
        fixture.panel.dismiss()
        clock.advance(by: .seconds(1))
        await push.value
        await close.value
        #expect(!fixture.panel.isPanelVisible)
        #expect(fixture.panel.stack.count == 1, "the push was dropped")
        #expect(fixture.hud.shown == ["Done Later"], "a close still shows its HUD")
    }

    @Test func anOutcomeFromAnEarlierSessionLeavesTheNewOneAlone() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let clock = fixture.runtime.fakes.clock
        let close = fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("late-close"), launch: .root)
        await clock.waitForSleepers(1)
        fixture.panel.dismiss()
        fixture.panel.summon()
        clock.advance(by: .seconds(1))
        await close.value
        #expect(fixture.panel.isPanelVisible, "the new session stays open")
    }

    @Test func aRunStartedWhileHiddenStillOpensThePanel() async throws {
        let fixture = await PanelFixture.make(summon: false)
        defer { fixture.close() }
        let clock = fixture.runtime.fakes.clock
        let push = fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("late-push"), launch: .hotkey)
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(1))
        await push.value
        #expect(fixture.panel.isPanelVisible)
        #expect(fixture.panel.top is ListPageController)
    }

    // MARK: Features switched off mid-run

    @Test func aFeatureSwitchedOffMidRunGetsNoOutcome() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let run = fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("stubborn"), launch: .root)
        await fixture.runtime.fakes.clock.waitForSleepers(1)
        await fixture.runtime.runtime.preferences.setEnabled(false, feature: "workbench")
        await run.value
        #expect(fixture.runtime.workbench.log == ["stubborn finished"], "the handler ignored its cancellation")
        #expect(fixture.panel.stack.count == 1, "its push was dropped")
    }

    @Test func switchingAFeatureOffClosesItsPages() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("open-shelf"), launch: .root)
        #expect(await waitUntil { fixture.topList?.loadCount == 1 })
        await fixture.runtime.runtime.preferences.setEnabled(false, feature: "workbench")
        #expect(await waitUntil { fixture.panel.top === fixture.panel.rootPage })
        #expect(fixture.field.leading == .root)
    }

    @Test func declarationsChangingMidRunLetTheRunFinish() async throws {
        let fixture = RuntimeFixture()
        await fixture.start()
        let workbench = fixture.workbench
        let run = fixture.runtime.pipeline.runCommand(RuntimeFixture.command("wait"), launch: .root)
        await fixture.fakes.clock.waitForSleepers(1)
        workbench.showsEcho = false
        workbench.declarations.send()
        #expect(await waitUntil { fixture.runtime.command(RuntimeFixture.command("echo")) == nil })
        fixture.fakes.clock.advance(by: .seconds(600))
        await run.value
        #expect(workbench.log == ["wait started", "wait finished"])
        await fixture.runtime.pipeline.runCommand(
            RuntimeFixture.command("echo"), arguments: ["text": "hi"], launch: .root
        ).value
        #expect(fixture.presenter.toasts.last?.title == "This command is not available")
        #expect(!workbench.log.contains("echo"))
    }

    // MARK: Lists

    @Test func aReloadDuringPagingDropsTheStalePage() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = GatedSource(titles: (1...60).map { "Note \($0)" })
        source.filtering = .custom(debounce: .zero)
        source.pageSize = 20
        let page = try #require(fixture.open(.list(ListPage(source, title: "Notes"))) as? ListPageController)
        #expect(await waitUntil { page.loadCount == 1 })
        source.gated = true
        page.list.scroll(to: 10_000)
        page.contentDidScroll()
        #expect(await waitUntil { source.gate.waiting == 1 }, "the next page is loading")
        page.reload()
        #expect(await waitUntil { source.gate.waiting == 2 }, "the reload is loading too")
        source.gate.open()
        #expect(await waitUntil { page.loadCount == 2 && source.loadsInFlight == 0 })
        #expect(page.list.content.rowCount == 20, "the stale page did not append to the reloaded rows")
        page.list.scroll(to: 10_000)
        page.contentDidScroll()
        #expect(await waitUntil { source.gate.waiting == 1 })
        page.contentDidScroll()
        #expect(source.requests.filter { $0.reason == .nextPage }.count == 2, "one next page at a time")
        source.gate.open()
        #expect(await waitUntil { page.list.content.rowCount == 40 })
        let titles = fixture.titles(page.list)
        #expect(Set(titles).count == titles.count, "no row twice")
    }

    @Test func aChangeSignalStormLoadsAtMostTwice() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = GatedSource(titles: ["alpha", "beta"])
        source.gated = true
        let page = try #require(fixture.open(.list(ListPage(source, title: "Notes"))) as? ListPageController)
        #expect(await waitUntil { source.gate.waiting == 1 })
        for _ in 0..<200 { source.changes?.send() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(source.requests.count == 1, "the storm waits for the load that runs")
        source.gate.open()
        #expect(await waitUntil { source.gate.waiting == 1 }, "one reload after it")
        source.gate.open()
        #expect(await waitUntil { page.loadCount == 2 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(source.requests.map(\.reason) == [.open, .reload])
        #expect(fixture.titles(page.list) == ["alpha", "beta"])
    }

    @Test func typingWhileACustomListLoadsAppliesOnlyTheNewestQuery() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = GatedSource(titles: ["alpha", "alpine", "beta"])
        source.filtering = .custom(debounce: .zero)
        let page = try #require(fixture.open(.list(ListPage(source, title: "Notes"))) as? ListPageController)
        #expect(await waitUntil { page.loadCount == 1 })
        source.gated = true
        for text in ["a", "al", "alp", "alph"] { fixture.type(text) }
        #expect(await waitUntil { source.gate.waiting == 4 })
        source.gate.open()
        #expect(await waitUntil { source.loadsInFlight == 0 })
        #expect(await waitUntil { page.loadCount == 2 }, "only the newest load applied")
        #expect(fixture.titles(page.list) == ["alpha"])
        #expect(source.requests.map(\.query) == ["", "a", "al", "alp", "alph"])
    }

    /// A paste closes the panel through the handler and through the pasteboard, then its outcome
    /// closes it again. Only the first close does anything; the next summon is a fresh one.
    @Test func closingThePanelTwiceInOneRunIsHarmless() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.type("e")
        let ends = fixture.root.calls.filter { $0 == .end }.count
        await fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("close-twice"), launch: .root).value
        #expect(!fixture.panel.isPanelVisible)
        #expect(fixture.root.calls.filter { $0 == .end }.count == ends + 1, "one dismiss ended the session")
        #expect(fixture.hud.shown == ["Pasted"])
        fixture.panel.dismiss()
        #expect(fixture.hud.shown == ["Pasted"])
        let calls = fixture.root.calls.count
        fixture.panel.summon()
        #expect(fixture.panel.isPanelVisible)
        #expect(fixture.panel.top === fixture.panel.rootPage)
        #expect(fixture.root.calls[calls...].first == .begin, "the next summon begins a new session")
    }
}
