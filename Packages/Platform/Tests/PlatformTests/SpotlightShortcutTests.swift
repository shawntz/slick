import Foundation
import Kit
import Synchronization
import Testing

@testable import Platform

/// Spotlight's shortcuts: which one uses a combination, the change to the stored dictionary, and
/// the hotkey center that turns one off only when asked and only for Spotlight. Every dictionary
/// here is made by the test; nothing reads or writes the Mac's own settings, and the live switch is
/// never made.
@Suite(.timeLimit(.minutes(1))) struct SpotlightShortcutTests {
    static let command = CarbonModifiers.command
    static let space = Key.space.code

    /// A stored dictionary as macOS keeps one, with Spotlight's search on its own keys, the Finder
    /// search window turned off and two shortcuts of other kinds.
    static func stored() -> [String: Any] {
        [
            "64": [
                "enabled": true,
                "value": ["parameters": [32, 49, 1_048_576], "type": "standard"] as [String: Any],
            ] as [String: Any],
            "65": ["enabled": false, "value": ["parameters": [32, 49, 1_572_864], "type": "standard"]] as [String: Any],
            "32": ["enabled": true, "value": ["parameters": [65_535, 126, 8_650_752], "type": "standard"]]
                as [String: Any],
            "60": ["enabled": false] as [String: Any],
        ]
    }

    // MARK: The stored dictionary

    @Test func anEntryThatExistsKeepsItsValueAndEveryOtherEntryStays() throws {
        let before = Self.stored()
        let after = try #require(SymbolicHotkeyPreferences.setting(false, .search, in: before))
        let entry = try #require(after["64"] as? [String: Any])
        #expect(entry["enabled"] as? Bool == false)
        #expect(
            NSDictionary(dictionary: entry["value"] as? [String: Any] ?? [:]).isEqual(to: [
                "parameters": [32, 49, 1_048_576], "type": "standard",
            ]))
        var others = after
        others["64"] = nil
        var expected = before
        expected["64"] = nil
        #expect(NSDictionary(dictionary: others).isEqual(to: expected))
        #expect(after.count == before.count)
    }

    @Test func anEntryKeepsKeysItDoesNotKnow() throws {
        var before = Self.stored()
        before["64"] =
            ["enabled": true, "value": ["parameters": [32, 49, 1_179_648]], "note": "kept"] as [String: Any]
        let after = try #require(SymbolicHotkeyPreferences.setting(false, .search, in: before))
        let entry = try #require(after["64"] as? [String: Any])
        #expect(entry["note"] as? String == "kept")
        #expect(((entry["value"] as? [String: Any])?["parameters"] as? [Int]) == [32, 49, 1_179_648])
    }

    @Test func aMissingEntryGetsTheSystemDefaultTurnedOff() throws {
        var before = Self.stored()
        before["64"] = nil
        before["65"] = nil
        let search = try #require(SymbolicHotkeyPreferences.setting(false, .search, in: before))
        let searchEntry = try #require(search["64"] as? [String: Any])
        #expect(searchEntry["enabled"] as? Bool == false)
        #expect(
            NSDictionary(dictionary: searchEntry["value"] as? [String: Any] ?? [:])
                .isEqual(to: ["parameters": [32, 49, 1_048_576], "type": "standard"]))
        #expect(search["65"] == nil)
        let finder = try #require(SymbolicHotkeyPreferences.setting(false, .finderSearch, in: before))
        let finderEntry = try #require(finder["65"] as? [String: Any])
        #expect(finderEntry["enabled"] as? Bool == false)
        #expect(
            ((finderEntry["value"] as? [String: Any])?["parameters"] as? [Int]) == [32, 49, 1_572_864])
        #expect(finder["64"] == nil)
        #expect(finder.count == before.count + 1)
    }

    @Test func somethingThatIsNotADictionaryIsRefused() {
        #expect(SymbolicHotkeyPreferences.setting(false, .search, in: nil) == nil)
        #expect(SymbolicHotkeyPreferences.setting(false, .search, in: "AppleSymbolicHotKeys") == nil)
        #expect(SymbolicHotkeyPreferences.setting(false, .search, in: [64, 65]) == nil)
        var broken = Self.stored()
        broken["64"] = "not an entry"
        #expect(SymbolicHotkeyPreferences.setting(false, .search, in: broken) == nil)
    }

    @Test func turningBackOnKeepsTheValueToo() throws {
        let off = try #require(SymbolicHotkeyPreferences.setting(false, .search, in: Self.stored()))
        let on = try #require(SymbolicHotkeyPreferences.setting(true, .search, in: off))
        #expect(NSDictionary(dictionary: on).isEqual(to: Self.stored()))
    }

    // MARK: Which shortcut uses the keys

    @Test func findsSpotlightsSearchOnItsKeysOnlyWhileItIsOn() {
        let stored = Self.stored()
        #expect(SymbolicHotkeyPreferences.shortcut(keyCode: Self.space, modifiers: Self.command, in: stored) == .search)
        // The Finder search window is off in this dictionary.
        let optionCommand = Self.command | CarbonModifiers.option
        #expect(SymbolicHotkeyPreferences.shortcut(keyCode: Self.space, modifiers: optionCommand, in: stored) == nil)
        // A missing entry is the system's default, which is on.
        var defaults = stored
        defaults["64"] = nil
        defaults["65"] = nil
        #expect(
            SymbolicHotkeyPreferences.shortcut(keyCode: Self.space, modifiers: Self.command, in: defaults) == .search)
        #expect(
            SymbolicHotkeyPreferences.shortcut(keyCode: Self.space, modifiers: optionCommand, in: defaults)
                == .finderSearch)
        // Turned off, it holds nothing.
        var off = stored
        off["64"] = ["enabled": false, "value": ["parameters": [32, 49, 1_048_576]]] as [String: Any]
        #expect(SymbolicHotkeyPreferences.shortcut(keyCode: Self.space, modifiers: Self.command, in: off) == nil)
    }

    @Test func followsSpotlightToTheKeysThePersonGaveIt() {
        var moved = Self.stored()
        // Control-Option-Space, with Spotlight's search moved there.
        moved["64"] =
            ["enabled": true, "value": ["parameters": [32, 49, 786_432], "type": "standard"]] as [String: Any]
        let controlOption = CarbonModifiers.control | CarbonModifiers.option
        #expect(SymbolicHotkeyPreferences.shortcut(keyCode: Self.space, modifiers: controlOption, in: moved) == .search)
        #expect(SymbolicHotkeyPreferences.shortcut(keyCode: Self.space, modifiers: Self.command, in: moved) == nil)
    }

    @Test func otherShortcutsAndWhatIsNotADictionaryAreNeverSpotlights() {
        // Mission Control's default is Control-Up.
        #expect(
            SymbolicHotkeyPreferences.shortcut(
                keyCode: Key.upArrow.code, modifiers: CarbonModifiers.control, in: Self.stored()) == nil)
        #expect(SymbolicHotkeyPreferences.shortcut(keyCode: Self.space, modifiers: Self.command, in: nil) == nil)
        #expect(SymbolicHotkeyPreferences.shortcut(keyCode: Self.space, modifiers: Self.command, in: "text") == nil)
    }

    @Test func eventFlagsBecomeCarbonModifiers() {
        #expect(SymbolicHotkeyPreferences.carbonModifiers(eventFlags: 1_048_576) == CarbonModifiers.command)
        #expect(
            SymbolicHotkeyPreferences.carbonModifiers(eventFlags: 1_572_864)
                == CarbonModifiers.command | CarbonModifiers.option)
        #expect(
            SymbolicHotkeyPreferences.carbonModifiers(eventFlags: 8_650_752)
                == CarbonModifiers.control | CarbonModifiers.function)
        #expect(SymbolicHotkeyPreferences.carbonModifiers(eventFlags: 131_072) == CarbonModifiers.shift)
    }

    // MARK: The hotkey center

    @Test func spotlightsConflictCanBeTurnedOffAndAnotherCannot() {
        let system = InertHotkeySystem()
        let switcher = RecordingSwitch(system: system)
        let hotkeys = HotkeyCenter(system: system, shortcuts: switcher)
        let spotlight = KeyCombo(.space, .command)
        let missionControl = KeyCombo(.upArrow, .control)
        system.setSymbolicHotkeys([SymbolicHotkey(holding: spotlight), SymbolicHotkey(holding: missionControl)])
        #expect(
            hotkeys.conflicts(for: spotlight) == [
                HotkeyConflict(owner: "Spotlight", canOverride: false, isSystemShortcut: true, canTurnOff: true)
            ])
        #expect(
            hotkeys.conflicts(for: missionControl) == [
                HotkeyConflict(owner: "Mission Control", canOverride: false, isSystemShortcut: true)
            ])
        #expect(switcher.changes.isEmpty)
    }

    @Test func turningOffSpotlightFreesTheKeysAndSaysWhichShortcut() async {
        let system = InertHotkeySystem()
        let switcher = RecordingSwitch(system: system)
        let hotkeys = HotkeyCenter(system: system, shortcuts: switcher)
        let spotlight = KeyCombo(.space, .command)
        system.setSymbolicHotkeys([SymbolicHotkey(holding: spotlight)])
        let turnedOff = await hotkeys.turnOffSystemShortcut(for: spotlight)
        #expect(turnedOff == SystemShortcut(number: 64, owner: "Spotlight"))
        #expect(switcher.changes.map(\.enabled) == [false])
        #expect(switcher.changes.map(\.shortcut) == [.search])
        #expect(hotkeys.conflicts(for: spotlight).isEmpty)
        // Back on, the same way.
        #expect(await hotkeys.turnOnSystemShortcut(SystemShortcut(number: 64, owner: "Spotlight")))
        #expect(switcher.changes.map(\.enabled) == [false, true])
        #expect(hotkeys.conflicts(for: spotlight).first?.canTurnOff == true)
    }

    @Test func anotherMacOSShortcutIsNeverTouched() async {
        let system = InertHotkeySystem()
        let switcher = RecordingSwitch(system: system)
        let hotkeys = HotkeyCenter(system: system, shortcuts: switcher)
        let missionControl = KeyCombo(.upArrow, .control)
        system.setSymbolicHotkeys([SymbolicHotkey(holding: missionControl)])
        #expect(await hotkeys.turnOffSystemShortcut(for: missionControl) == nil)
        // Keys nothing uses are not touched either.
        #expect(await hotkeys.turnOffSystemShortcut(for: KeyCombo(.k, [.command, .option])) == nil)
        #expect(await !hotkeys.turnOnSystemShortcut(SystemShortcut(number: 32, owner: "Mission Control")))
        #expect(switcher.changes.isEmpty)
        #expect(hotkeys.conflicts(for: missionControl).count == 1)
    }

    @Test func aSwitchThatFailsOrKeysStillTakenReportNothingTurnedOff() async {
        let system = InertHotkeySystem()
        let spotlight = KeyCombo(.space, .command)
        system.setSymbolicHotkeys([SymbolicHotkey(holding: spotlight)])

        let refusing = RecordingSwitch(system: system)
        refusing.refuses = true
        let hotkeys = HotkeyCenter(system: system, shortcuts: refusing)
        #expect(await hotkeys.turnOffSystemShortcut(for: spotlight) == nil)
        #expect(hotkeys.conflicts(for: spotlight).first?.isSystemShortcut == true)

        // The switch says it worked, but the system still reports the shortcut on.
        let silent = RecordingSwitch(system: system)
        silent.changesNothing = true
        let unchanged = HotkeyCenter(system: system, shortcuts: silent)
        #expect(await unchanged.turnOffSystemShortcut(for: spotlight) == nil)
        #expect(silent.changes.count == 1)
    }

    @Test func noSwitchMeansNoConflictCanBeTurnedOff() async {
        let system = FakeHotkeySystem()
        system.state.withLock { $0.symbolic = [SymbolicHotkey(holding: KeyCombo(.space, .command))] }
        let hotkeys = HotkeyCenter(system: system)
        #expect(hotkeys.shortcuts == nil)
        #expect(hotkeys.conflicts(for: KeyCombo(.space, .command)).first?.canTurnOff == false)
        #expect(await hotkeys.turnOffSystemShortcut(for: KeyCombo(.space, .command)) == nil)
    }

    @Test func theInertSwitchPlaysSpotlightOnItsDefaultKeysOnly() async {
        let system = InertHotkeySystem()
        let inert = InertSpotlightShortcutSwitch(system: system)
        #expect(HotkeyCenter(system: system).shortcuts is InertSpotlightShortcutSwitch)
        #expect(inert.shortcut(keyCode: Self.space, modifiers: Self.command) == nil)
        system.setSymbolicHotkeys([SymbolicHotkey(holding: KeyCombo(.space, .command))])
        #expect(inert.shortcut(keyCode: Self.space, modifiers: Self.command) == .search)
        inert.refusesChanges = true
        #expect(await !inert.setEnabled(false, .search))
        #expect(system.symbolicHotkeys().first?.isEnabled == true)
        inert.refusesChanges = false
        #expect(await inert.setEnabled(false, .search))
        #expect(system.symbolicHotkeys().first?.isEnabled == false)
        #expect(inert.shortcut(keyCode: Self.space, modifiers: Self.command) == nil)
        #expect(inert.changes.count == 2)
    }
}

/// A switch over an inert system that records every change, can refuse, or can report success
/// while changing nothing.
final class RecordingSwitch: SpotlightShortcutSwitch, @unchecked Sendable {
    private let inner: InertSpotlightShortcutSwitch
    private let state = Mutex<[(enabled: Bool, shortcut: SpotlightShortcut)]>([])
    var refuses = false
    var changesNothing = false

    init(system: InertHotkeySystem) {
        inner = InertSpotlightShortcutSwitch(system: system)
    }

    var changes: [(enabled: Bool, shortcut: SpotlightShortcut)] { state.withLock { $0 } }

    func shortcut(keyCode: UInt16, modifiers: UInt32) -> SpotlightShortcut? {
        inner.shortcut(keyCode: keyCode, modifiers: modifiers)
    }

    @concurrent func setEnabled(_ enabled: Bool, _ shortcut: SpotlightShortcut) async -> Bool {
        state.withLock { $0.append((enabled, shortcut)) }
        if refuses { return false }
        if changesNothing { return true }
        return await inner.setEnabled(enabled, shortcut)
    }
}
