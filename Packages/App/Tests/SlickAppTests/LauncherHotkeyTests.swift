import Kit
import KitHosting
import KitTesting
import SettingsUI
import Testing

@testable import SlickApp

@Suite("Launcher hotkey", .timeLimit(.minutes(1)))
struct LauncherHotkeyTests {
    /// Counts presses on the main actor.
    final class Presses {
        var count = 0
    }

    struct Fixture {
        let fakes = FakeServices()
        let presses = Presses()
        let retry = ChangeSignal()
        let hotkey: LauncherHotkey

        init() {
            let presses = presses
            hotkey = LauncherHotkey(
                hotkeys: fakes.hotkeys, settings: fakes.settings, retrySignal: retry, clock: fakes.clock,
                press: { presses.count += 1 })
        }

        var general: FeatureSettings { HostSettings.settings(fakes.settings) }
        var registered: KeyCombo? { fakes.hotkeys.registered[LauncherHotkey.bindingID] }
    }

    @Test func bindsTheDefaultAndTogglesOnPress() async {
        let fixture = Fixture()
        fixture.hotkey.start()
        #expect(fixture.registered == KeyCombo(.space, .command))
        #expect(fixture.hotkey.bound == KeyCombo(.space, .command))
        #expect(fixture.hotkey.wait == nil)
        #expect(!fixture.hotkey.isRechecking)
        #expect(fixture.fakes.clock.sleeperCount == 0)
        #expect(await fixture.fakes.hotkeys.press(LauncherHotkey.bindingID))
        #expect(fixture.presses.count == 1)
        fixture.hotkey.stop()
        #expect(fixture.registered == nil)
    }

    @Test func rebindsWhenTheSettingChanges() async {
        let fixture = Fixture()
        fixture.hotkey.start()
        let next = KeyCombo(.space, [.command, .shift])
        fixture.general[HostSettings.launcherHotkey] = next
        await fixture.fakes.settle()
        #expect(fixture.registered == next)
        #expect(fixture.hotkey.bound == next)
        #expect(await fixture.fakes.hotkeys.press(LauncherHotkey.bindingID))
        #expect(fixture.presses.count == 1)
        fixture.hotkey.stop()
    }

    @Test func unbindsWhenTheSettingIsCleared() async {
        let fixture = Fixture()
        fixture.hotkey.start()
        fixture.general[HostSettings.launcherHotkey] = nil
        await fixture.fakes.settle()
        #expect(fixture.registered == nil)
        #expect(fixture.hotkey.bound == nil)
        #expect(!fixture.hotkey.simulatePress())
        fixture.general[HostSettings.launcherHotkey] = KeyCombo(.k, [.command, .option])
        await fixture.fakes.settle()
        #expect(fixture.registered == KeyCombo(.k, [.command, .option]))
        fixture.hotkey.stop()
    }

    @Test func keepsTheOldBindingWhenANewOneIsRefusedAndRetriesLater() async throws {
        let fixture = Fixture()
        var refusals: [KeyCombo] = []
        fixture.hotkey.onRefusal = { combo, _ in refusals.append(combo) }
        fixture.hotkey.start()
        let taken = KeyCombo(.k, [.command, .option])
        fixture.fakes.hotkeys.addConflict(HotkeyConflict(owner: "Another binding", canOverride: false), for: taken)
        fixture.general[HostSettings.launcherHotkey] = taken
        await fixture.fakes.settle()
        #expect(fixture.registered == KeyCombo(.space, .command))
        #expect(fixture.hotkey.bound == KeyCombo(.space, .command))
        #expect(fixture.hotkey.refusal?.combo == taken)
        #expect(fixture.hotkey.wait == nil)
        #expect(!fixture.hotkey.isRechecking)
        #expect(refusals == [taken])

        // Retried when item hotkeys change; still refused, so nothing moves.
        fixture.retry.send()
        try await waitUntil { refusals.count == 2 }
        #expect(fixture.registered == KeyCombo(.space, .command))
        #expect(refusals == [taken, taken])
        fixture.hotkey.stop()
    }

    @Test func waitsBehindAMacOSShortcutRechecksOnTheClockAndBindsWhenFree() async throws {
        let fixture = Fixture()
        let spotlight = KeyCombo(.space, .command)
        fixture.fakes.hotkeys.addSystemShortcut(spotlight)
        var refusals: [KeyCombo] = []
        var freed: [KeyCombo] = []
        fixture.hotkey.onRefusal = { combo, _ in refusals.append(combo) }
        fixture.hotkey.onBoundAfterWait = { freed.append($0) }
        let changes = fixture.hotkey.statusChanges.stream()
        var seen = changes.makeAsyncIterator()

        fixture.hotkey.start()
        #expect(fixture.hotkey.wait == LauncherHotkeyWait(combo: spotlight, owner: "Spotlight"))
        #expect(fixture.hotkey.bound == nil)
        #expect(fixture.registered == nil)
        #expect(fixture.hotkey.refusal == nil)
        #expect(refusals.isEmpty)
        #expect(!fixture.hotkey.simulatePress())
        #expect(await seen.next() != nil)

        // Every two seconds at first, and still held: nothing changes.
        await fixture.fakes.clock.waitForSleepers()
        fixture.fakes.clock.advance(by: .seconds(2))
        await fixture.fakes.clock.waitForSleepers()
        #expect(fixture.hotkey.wait != nil)
        #expect(fixture.fakes.clock.sleeperCount == 1)

        // The user turns Spotlight's shortcut off; the next check binds it and stops the timer.
        fixture.fakes.hotkeys.removeConflicts(for: spotlight)
        fixture.fakes.clock.advance(by: .seconds(2))
        try await waitUntil { fixture.hotkey.bound == spotlight }
        #expect(fixture.registered == spotlight)
        #expect(fixture.hotkey.wait == nil)
        #expect(freed == [spotlight])
        #expect(refusals.isEmpty)
        #expect(!fixture.hotkey.isRechecking)
        try await waitUntil { fixture.fakes.clock.sleeperCount == 0 }
        #expect(await seen.next() != nil)
        #expect(await fixture.fakes.hotkeys.press(LauncherHotkey.bindingID))
        #expect(fixture.presses.count == 1)
        fixture.hotkey.stop()
    }

    @Test func checksEveryThirtySecondsAfterTheFirstTenMinutes() async throws {
        let fixture = Fixture()
        let spotlight = KeyCombo(.space, .command)
        fixture.fakes.hotkeys.addSystemShortcut(spotlight)
        fixture.hotkey.start()
        // Ten minutes of two-second checks.
        for _ in 0..<300 {
            await fixture.fakes.clock.waitForSleepers()
            fixture.fakes.clock.advance(by: .seconds(2))
        }
        await fixture.fakes.clock.waitForSleepers()
        fixture.fakes.hotkeys.removeConflicts(for: spotlight)
        // Two seconds no longer wake the timer.
        fixture.fakes.clock.advance(by: .seconds(2))
        await Task.yield()
        #expect(fixture.hotkey.bound == nil)
        fixture.fakes.clock.advance(by: .seconds(28))
        try await waitUntil { fixture.hotkey.bound == spotlight }
        #expect(!fixture.hotkey.isRechecking)
        fixture.hotkey.stop()
    }

    @Test func aCheckWhenAWindowOpensBindsAtOnce() async throws {
        let fixture = Fixture()
        let spotlight = KeyCombo(.space, .command)
        fixture.fakes.hotkeys.addSystemShortcut(spotlight)
        fixture.hotkey.start()
        #expect(fixture.hotkey.wait != nil)
        fixture.hotkey.checkNow()
        #expect(fixture.hotkey.bound == nil)
        fixture.fakes.hotkeys.removeConflicts(for: spotlight)
        fixture.hotkey.checkNow()
        #expect(fixture.hotkey.bound == spotlight)
        #expect(!fixture.hotkey.isRechecking)
        // Bound: a check does nothing and starts no timer.
        fixture.hotkey.checkNow()
        #expect(!fixture.hotkey.isRechecking)
        fixture.hotkey.stop()
    }

    @Test func recordingAnotherHotkeyEndsTheWaitAndAWaitUnbindsTheOldOne() async throws {
        let fixture = Fixture()
        fixture.hotkey.start()
        #expect(fixture.hotkey.bound == KeyCombo(.space, .command))
        // Another combination that a macOS shortcut holds: the old binding goes, nothing is bound.
        let held = KeyCombo(.space, .control)
        fixture.fakes.hotkeys.addSystemShortcut(held, owner: "Select the previous input source")
        fixture.general[HostSettings.launcherHotkey] = held
        await fixture.fakes.settle()
        #expect(fixture.registered == nil)
        #expect(fixture.hotkey.wait?.owner == "Select the previous input source")
        #expect(fixture.hotkey.isRechecking)
        // A free combination ends the wait without the freed HUD.
        var freed: [KeyCombo] = []
        fixture.hotkey.onBoundAfterWait = { freed.append($0) }
        let free = KeyCombo(.k, [.command, .option])
        fixture.general[HostSettings.launcherHotkey] = free
        await fixture.fakes.settle()
        #expect(fixture.registered == free)
        #expect(fixture.hotkey.wait == nil)
        #expect(!fixture.hotkey.isRechecking)
        #expect(freed.isEmpty)
        fixture.hotkey.stop()
    }

    @Test func aRefusedSettingWinsOnceTheConflictIsGone() async throws {
        let fakes = FakeServices()
        let hotkeys = ConflictingHotkeys(base: fakes.hotkeys)
        let retry = ChangeSignal()
        let hotkey = LauncherHotkey(
            hotkeys: hotkeys, settings: fakes.settings, retrySignal: retry, clock: fakes.clock, press: {})
        hotkey.start()
        let wanted = KeyCombo(.j, [.command, .option])
        hotkeys.blocked = wanted
        HostSettings.settings(fakes.settings)[HostSettings.launcherHotkey] = wanted
        await fakes.settle()
        #expect(hotkey.bound == KeyCombo(.space, .command))
        #expect(hotkey.wait == nil)
        hotkeys.blocked = nil
        retry.send()
        try await waitUntil { hotkey.bound == wanted }
        #expect(fakes.hotkeys.registered[LauncherHotkey.bindingID] == wanted)
        hotkey.stop()
    }
}

/// A hotkey service that refuses one combination until told otherwise, as when an item still
/// holds the chord settings just gave to the launcher.
final class ConflictingHotkeys: HotkeyService, @unchecked Sendable {
    let base: FakeHotkeys
    var blocked: KeyCombo?

    init(base: FakeHotkeys) {
        self.base = base
    }

    func register(_ combo: KeyCombo, id: String, handler: @escaping @MainActor @Sendable () -> Void) throws {
        if combo == blocked { throw HotkeyError.conflict([HotkeyConflict(owner: "cmd:x.y", canOverride: true)]) }
        try base.register(combo, id: id, handler: handler)
    }

    func unregister(id: String) {
        base.unregister(id: id)
    }

    func conflicts(for combo: KeyCombo) -> [HotkeyConflict] {
        base.conflicts(for: combo)
    }
}

/// Waits for a condition on the main actor, giving up after two seconds.
func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("condition did not hold within 2 s")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}
