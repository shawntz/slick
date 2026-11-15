import Kit
import KitHosting
import KitTesting
import Testing

@testable import SlickApp

@Suite("Launcher hotkey")
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
                hotkeys: fakes.hotkeys, settings: fakes.settings, retrySignal: retry, press: { presses.count += 1 })
        }

        var general: FeatureSettings { HostSettings.settings(fakes.settings) }
        var registered: KeyCombo? { fakes.hotkeys.registered[LauncherHotkey.bindingID] }
    }

    @Test func bindsTheDefaultAndTogglesOnPress() async {
        let fixture = Fixture()
        fixture.hotkey.start()
        #expect(fixture.registered == KeyCombo(.space, .option))
        #expect(fixture.hotkey.bound == KeyCombo(.space, .option))
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
        let taken = KeyCombo(.space, .command)
        fixture.fakes.hotkeys.addConflict(HotkeyConflict(owner: "Spotlight", canOverride: false), for: taken)
        fixture.general[HostSettings.launcherHotkey] = taken
        await fixture.fakes.settle()
        #expect(fixture.registered == KeyCombo(.space, .option))
        #expect(fixture.hotkey.bound == KeyCombo(.space, .option))
        #expect(fixture.hotkey.refusal?.combo == taken)
        #expect(refusals == [taken])

        // Retried when item hotkeys change; still refused, so nothing moves.
        fixture.retry.send()
        try await waitUntil { refusals.count == 2 }
        #expect(fixture.registered == KeyCombo(.space, .option))
        #expect(refusals == [taken, taken])
        fixture.hotkey.stop()
    }

    @Test func aRefusedSettingWinsOnceTheConflictIsGone() async throws {
        let fakes = FakeServices()
        let hotkeys = ConflictingHotkeys(base: fakes.hotkeys)
        let retry = ChangeSignal()
        let hotkey = LauncherHotkey(hotkeys: hotkeys, settings: fakes.settings, retrySignal: retry, press: {})
        hotkey.start()
        let wanted = KeyCombo(.j, [.command, .option])
        hotkeys.blocked = wanted
        HostSettings.settings(fakes.settings)[HostSettings.launcherHotkey] = wanted
        await fakes.settle()
        #expect(hotkey.bound == KeyCombo(.space, .option))
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
