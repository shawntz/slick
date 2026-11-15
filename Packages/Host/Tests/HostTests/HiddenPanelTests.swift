import AppKit
import Foundation
import Host
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import Testing

/// What happens while the panel is hidden: pages wait and reload once, the summon strategy follows
/// its setting, Tab follows Root's snapshot, and subtitle colors stay readable.
@Suite("Panel: hidden pages and settings", .serialized, .timeLimit(.minutes(1)))
@MainActor struct HiddenPanelTests {
    private func openShelf(_ fixture: PanelFixture) async -> ListPageController? {
        fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("open-shelf"), launch: .root)
        guard await waitUntil({ fixture.topList?.loadCount == 1 }) else { return nil }
        return fixture.topList
    }

    private func hide(_ fixture: PanelFixture) {
        fixture.panel.summoner.dismiss(returnFocus: false)
    }

    /// Lets tasks that should not run have their chance.
    private func pause() async {
        try? await Task.sleep(for: .milliseconds(30))
    }

    @Test func aHiddenListRemembersChangesAndReloadsOnceWhenShown() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let page = try #require(await openShelf(fixture))
        hide(fixture)
        let shelf = fixture.runtime.workbench.shelf
        shelf.items.append("Damson")
        shelf.changes?.send()
        shelf.changes?.send()
        fixture.runtime.fakes.settings.set(.string("date"), for: "workbench.sort")
        await pause()
        #expect(page.loadCount == 1, "nothing loads while the panel is hidden")

        fixture.panel.summon()
        #expect(await waitUntil { page.loadCount == 2 })
        await pause()
        #expect(page.loadReasons == [.open, .reload], "one reload for every change that arrived")
        #expect(fixture.titles(page.list).contains("Damson"))

        shelf.changes?.send()
        #expect(await waitUntil { page.loadCount == 3 }, "it listens again once shown")
    }

    @Test func aRefreshThatCameDueWhileHiddenLoadsWhenShown() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let clock = fixture.runtime.fakes.clock
        fixture.runtime.workbench.shelf.refreshAfter = .seconds(5)
        let page = try #require(await openShelf(fixture))
        await clock.waitForSleepers(1)
        hide(fixture)
        clock.advance(by: .seconds(10))
        await pause()
        #expect(!page.loadReasons.contains(.refresh), "the timer waits while hidden")

        fixture.panel.summon()
        #expect(await waitUntil { page.loadReasons.contains(.refresh) })
        #expect(page.loadReasons == [.open, .refresh])
    }

    @Test func aReloadAskedForWhileHiddenWaitsForTheNextShow() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let page = try #require(await openShelf(fixture))
        hide(fixture)
        fixture.panel.reloadTopPage()
        await pause()
        #expect(page.loadCount == 1)
        fixture.panel.summon()
        #expect(await waitUntil { page.loadCount == 2 })
        #expect(page.loadReasons == [.open, .reload])
    }

    @Test func theSummonStrategyFollowsItsSettingWhileHidden() async {
        let fixture = await PanelFixture.make(summon: false)
        defer { fixture.close() }
        let general = HostSettings.settings(fixture.runtime.fakes.settings)
        let probe = fixture.panel.summoner.probe
        #expect(fixture.panel.summoner.strategy == .layerOpacity)

        general[HostSettings.summonStrategy] = .orderFront
        #expect(await waitUntil { fixture.panel.summoner.strategy == .orderFront })
        #expect(fixture.panel.summoner.probe === probe, "the latency probe carries over")
        #expect(!fixture.panel.summoner.takesKeyStatus, "test settings carry over")
        #expect(!fixture.panel.surface.panel.isVisible, "the hidden panel is ordered out")

        fixture.panel.summon()
        #expect(fixture.panel.isPanelVisible)
        general[HostSettings.summonStrategy] = .layerOpacity
        await pause()
        #expect(fixture.panel.summoner.strategy == .orderFront, "no switch while the panel shows")
        fixture.panel.summoner.dismiss(returnFocus: false)
        #expect(fixture.panel.summoner.strategy == .layerOpacity, "the dismiss switches")
        #expect(!fixture.panel.isPanelVisible)
        fixture.panel.summon()
        #expect(fixture.panel.isPanelVisible)
    }

    @Test func tabRunsOnlyTheCommandRootPutInTheSnapshot() async {
        let receive = ItemID.command(feature: "relay", command: "receive")
        let fixture = await PanelFixture.make(settings: ["tabCommand": .string(receive.rawValue)])
        defer { fixture.close() }
        fixture.type("zzz")
        fixture.press(.complete)
        await pause()
        #expect(fixture.runtime.relay.received.isEmpty, "the setting alone runs nothing")
        fixture.root.tabCommand = receive
        fixture.type("zzy")
        fixture.press(.complete)
        #expect(await waitUntil { fixture.runtime.relay.received == [CommandArguments(["text": "zzy"])] })
    }

    @Test func aSubtitleColorStaysWithinTheThemesContrast() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let mapper = fixture.panel.rowMapper
        let theme = fixture.panel.resolvedTheme
        #expect(!theme.isDark)
        let reference = LegibleColor.lightReferenceLuminance
        let row = Row(id: ItemID("script", "status"), title: "Status", subtitle: "failed")
        #expect(mapper.subtitleColor(for: row) == nil, "no color draws the theme's")

        var pale = row
        pale.subtitleColor = .rgba(red: 1, green: 1, blue: 0.4, alpha: 1)
        let darkened = try #require(mapper.subtitleColor(for: pale).flatMap { Luminance.over($0, base: 1) })
        #expect(LegibleColor.ratio(darkened, reference) >= RowMapper.subtitleContrast - 0.001)

        var deep = row
        deep.subtitleColor = .rgba(red: 0.3, green: 0, blue: 0, alpha: 1)
        let kept = try #require(mapper.subtitleColor(for: deep))
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let components = try #require(kept.converted(to: sRGB, intent: .defaultIntent, options: nil)?.components)
        #expect(abs(components[0] - 0.3) < 0.001 && components[1] < 0.001, "a readable color is kept as asked")
    }
}

/// Relative luminance of a color drawn over a grey base, as the contrast rule measures it.
enum Luminance {
    static func over(_ color: CGColor, base: Double) -> Double? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let parts = color.converted(to: space, intent: .defaultIntent, options: nil)?.components, parts.count == 4
        else { return nil }
        func linear(_ value: Double) -> Double {
            value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let alpha = Double(parts[3])
        let channels = (0..<3).map { Double(parts[$0]) * alpha + base * (1 - alpha) }
        return 0.2126 * linear(channels[0]) + 0.7152 * linear(channels[1]) + 0.0722 * linear(channels[2])
    }
}
