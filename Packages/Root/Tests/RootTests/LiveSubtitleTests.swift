import CoreBridge
import Foundation
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Testing

@testable import Root

/// Live subtitles refresh while their command row is visible and stop when root search leaves the
/// screen.
@Suite(.timeLimit(.minutes(1))) struct LiveSubtitleTests {
    static func subtitle(_ fixture: RootFixture) -> String? {
        fixture.root.snapshot.rows.first { $0.title == "Disk Status" }?.subtitle
    }

    @Test func aVisibleCommandRefreshesAtLeastTenSecondsApartAndOnItsSignal() async throws {
        let fixture = await RootFixture.ready(signals: true)
        let disk = try fixture.signalsFeature().disk
        _ = fixture.root.begin()
        let typed = fixture.root.update(query: "disk status")
        #expect(typed.rows.first?.subtitle == "Signals")
        await fixture.settle()
        #expect(disk.fetches == 1)
        #expect(Self.subtitle(fixture) == "Disk ok 1")

        // The command asks for two seconds; root waits ten.
        fixture.clock.advance(by: .seconds(2))
        await fixture.settle()
        #expect(disk.fetches == 1)
        fixture.clock.advance(by: .seconds(8))
        await fixture.settle()
        #expect(disk.fetches == 2)
        #expect(Self.subtitle(fixture) == "Disk ok 2")

        disk.signal.send()
        await fixture.settle()
        #expect(disk.fetches == 3)

        // The next keystroke shows the last value at once.
        #expect(fixture.root.update(query: "disk stat").rows.first?.subtitle == "Disk ok 3")
        fixture.root.end()
        await fixture.shutdown()
    }

    @Test func refreshesStopWhenRootSearchLeavesTheScreenOrTheRowLeavesTheList() async throws {
        let fixture = await RootFixture.ready(signals: true)
        let disk = try fixture.signalsFeature().disk
        _ = fixture.root.begin()
        _ = fixture.root.update(query: "disk status")
        await fixture.settle()
        #expect(disk.fetches == 1)
        fixture.root.end()
        #expect(fixture.root.subtitleRunners.isEmpty)
        fixture.clock.advance(by: .seconds(30))
        disk.signal.send()
        await fixture.settle()
        #expect(disk.fetches == 1)

        _ = fixture.root.begin()
        _ = fixture.root.update(query: "disk status")
        await fixture.settle()
        #expect(disk.fetches == 2)
        _ = fixture.root.update(query: "calendar")
        #expect(fixture.root.subtitleRunners.isEmpty)
        fixture.root.end()
        await fixture.shutdown()
    }

    /// After a declaration change a command may hand a new signal or interval. Root follows the
    /// new one and lets the old one go; the same ones keep the running loop.
    @Test func aNewSignalOrIntervalAfterADeclarationChangeRestartsTheLoop() async throws {
        let fixture = await RootFixture.ready(signals: true)
        let disk = try fixture.signalsFeature().disk
        _ = fixture.root.begin()
        _ = fixture.root.update(query: "disk status")
        await fixture.settle()
        #expect(disk.fetches == 1)

        fixture.directory.reload(SignalsFeature.manifest.id)
        await fixture.settle()
        #expect(disk.fetches == 1, "the same signal and interval keep the running loop")

        let old = disk.signal
        disk.signal = ChangeSignal()
        fixture.directory.reload(SignalsFeature.manifest.id)
        await fixture.settle()
        #expect(disk.fetches == 2, "the new loop fetches at once")
        old.send()
        await fixture.settle()
        #expect(disk.fetches == 2, "the old signal is no longer followed")
        disk.signal.send()
        await fixture.settle()
        #expect(disk.fetches == 3)

        disk.interval = .seconds(20)
        fixture.directory.reload(SignalsFeature.manifest.id)
        await fixture.settle()
        #expect(disk.fetches == 4)
        fixture.clock.advance(by: .seconds(10))
        await fixture.settle()
        #expect(disk.fetches == 4, "the old ten-second loop stopped")
        fixture.clock.advance(by: .seconds(10))
        await fixture.settle()
        #expect(disk.fetches == 5)
        fixture.root.end()
        await fixture.shutdown()
    }

    @Test func onlyRowsTheListShowsBeforeItScrollsRefresh() async throws {
        let fixture = await RootFixture.ready(extraSources: [NumberedItems(count: 30)], signals: true)
        let disk = try fixture.signalsFeature().disk
        fixture.general[HostSettings.visibleRows] = 1
        await fixture.settle()
        _ = fixture.root.begin()
        // "s" matches many items; the disk command is not the first row.
        let snapshot = fixture.root.update(query: "status")
        #expect(snapshot.rows.first?.title == "Disk Status")
        await fixture.settle()
        #expect(disk.fetches == 1)
        _ = fixture.root.update(query: "s")
        #expect(fixture.root.snapshot.rows.first?.title != "Disk Status")
        #expect(fixture.root.subtitleRunners.isEmpty)
        fixture.root.end()
        await fixture.shutdown()
    }
}

/// Tab: the snapshot's completion, and the Tab command a typed snapshot carries.
@Suite struct TabTests {
    @Test func theTabCommandMustBeOnAndTakeTheRootQuery() async throws {
        let fixture = await RootFixture.ready(signals: true)
        #expect(fixture.root.tabCommand == nil)
        fixture.general[HostSettings.tabCommand] = "cmd:signals.ask"
        await fixture.settle()
        #expect(fixture.root.tabCommand == .command(feature: "signals", command: "ask"))

        fixture.general[HostSettings.tabCommand] = "cmd:signals.plain"
        await fixture.settle()
        #expect(fixture.root.tabCommand == nil)

        fixture.general[HostSettings.tabCommand] = "cmd:signals.ask"
        await fixture.preferences.setEnabled(false, feature: SignalsFeature.manifest.id)
        await fixture.settle()
        #expect(fixture.root.tabCommand == nil)
        await fixture.shutdown()
    }

    @Test func typedSnapshotsCarryTheTabCommand() async throws {
        let fixture = await RootFixture.ready(signals: true)
        let root = fixture.root
        let ask = ItemID.command(feature: "signals", command: "ask")
        #expect(root.begin().tabCommand == nil)
        #expect(root.update(query: "calen").tabCommand == nil, "no Tab command is chosen")

        fixture.general[HostSettings.tabCommand] = ask.rawValue
        await fixture.settle()
        #expect(root.snapshot.tabCommand == ask, "a change mid-session reaches the snapshot on screen")
        #expect(root.update(query: "zzqqxx").tabCommand == ask)
        #expect(root.update(query: "   ").tabCommand == nil, "a blank query is the empty state")

        fixture.general[HostSettings.tabCommand] = "cmd:signals.plain"
        await fixture.settle()
        #expect(root.update(query: "zzqqxx").tabCommand == nil, "the command does not take the root query")
        root.end()
        await fixture.shutdown()
    }

    @Test func aTopRowsOwnCompletionIsTheSnapshotsCompletion() async throws {
        let fixture = await RootFixture.ready(signals: true)
        let root = fixture.root
        _ = root.begin()
        let typed = root.update(query: "@ab")
        #expect(typed.completion == nil)
        await fixture.passDebounce()
        let completion = try #require(root.snapshot.completion)
        #expect(completion.id == ItemID("mail", "@ab-0"))
        #expect(completion.text == "@@ab-0")

        fixture.general[HostSettings.inlineCompletion] = false
        await fixture.settle()
        _ = root.update(query: "@abc")
        await fixture.passDebounce()
        #expect(root.snapshot.completion == nil)
        root.end()
        await fixture.shutdown()
    }
}
