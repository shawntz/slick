import Carbon
import Foundation
import Kit
import Synchronization
import Testing

@testable import Platform

@Suite(.timeLimit(.minutes(1))) struct HotkeyTests {
    let system = FakeHotkeySystem()

    @Test func registeringRecordsTheChordAndAPressRunsTheHandler() throws {
        let hotkeys = HotkeyCenter(system: system)
        let pressed = Counter()
        try hotkeys.register(KeyCombo(.k, [.command, .shift]), id: "cmd:notes.open") { pressed.increment() }
        let registration = try #require(system.registrations.first)
        #expect(registration.keyCode == UInt32(Key.k.code))
        #expect(registration.modifiers == CarbonModifiers.command | CarbonModifiers.shift)
        #expect(hotkeys.registered == ["cmd:notes.open": KeyCombo(.k, [.command, .shift])])

        system.press(number: registration.number)
        system.press(number: 9_999)
        #expect(pressed.value == 1)
        hotkeys.dispatch(number: try #require(hotkeys.number(for: "cmd:notes.open")))
        #expect(pressed.value == 2)

        hotkeys.unregister(id: "cmd:notes.open")
        hotkeys.unregister(id: "never-registered")
        #expect(hotkeys.registered.isEmpty)
        #expect(system.registrations.isEmpty)
    }

    @Test func ownRegistrationsConflictAndCanBeTakenOver() throws {
        let hotkeys = HotkeyCenter(system: system)
        let combo = KeyCombo(.j, [.control, .option])
        try hotkeys.register(combo, id: "first") {}
        #expect(throws: HotkeyError.conflict([HotkeyConflict(owner: "first", canOverride: true)])) {
            try hotkeys.register(combo, id: "second") {}
        }
        #expect(hotkeys.conflicts(for: combo) == [HotkeyConflict(owner: "first", canOverride: true)])
        #expect(hotkeys.conflicts(for: combo, excluding: "first").isEmpty)
        // The host takes it over by unregistering the other item first.
        hotkeys.unregister(id: "first")
        try hotkeys.register(combo, id: "second") {}
        #expect(hotkeys.registered == ["second": combo])
    }

    @Test func enabledSystemShortcutsConflictAndCannotBeOverridden() {
        system.state.withLock { state in
            state.symbolic = [
                SymbolicHotkey(keyCode: Key.space.code, modifiers: CarbonModifiers.command, isEnabled: true),
                SymbolicHotkey(keyCode: Key.f.code, modifiers: CarbonModifiers.control, isEnabled: false),
                SymbolicHotkey(
                    keyCode: Key.g.code, modifiers: CarbonModifiers.control | CarbonModifiers.function, isEnabled: true),
            ]
        }
        let hotkeys = HotkeyCenter(system: system)
        let spotlight = KeyCombo(.space, .command)
        #expect(
            hotkeys.conflicts(for: spotlight) == [
                HotkeyConflict(owner: "Spotlight", canOverride: false, isSystemShortcut: true)
            ])
        #expect(throws: HotkeyError.self) { try hotkeys.register(spotlight, id: "launcher") {} }
        #expect(system.registrations.isEmpty)
        #expect(hotkeys.conflicts(for: KeyCombo(.f, .control)).isEmpty)  // turned off
        #expect(hotkeys.conflicts(for: KeyCombo(.g, .control)).isEmpty)  // needs Function too
        #expect(hotkeys.conflicts(for: KeyCombo(.g, [.control, .function])).first?.canOverride == false)
    }

    @Test func onlyAMacOSShortcutIsMarkedAsOne() throws {
        let combo = KeyCombo(.space, .command)
        system.state.withLock { $0.symbolic = [SymbolicHotkey(holding: combo)] }
        let hotkeys = HotkeyCenter(system: system)
        let other = KeyCombo(.j, [.control, .option])
        try hotkeys.register(other, id: "first") {}
        #expect(hotkeys.conflicts(for: combo).map(\.isSystemShortcut) == [true])
        #expect(hotkeys.conflicts(for: other).map(\.isSystemShortcut) == [false])
        // Turning the shortcut off frees the combination.
        system.state.withLock { $0.symbolic[0].isEnabled = false }
        #expect(hotkeys.conflicts(for: combo).isEmpty)
        try hotkeys.register(combo, id: "launcher") {}
        #expect(hotkeys.registered["launcher"] == combo)
    }

    @Test func theInertSystemPlaysTheShortcutsAScenarioSets() throws {
        let inert = InertHotkeySystem()
        let hotkeys = HotkeyCenter(system: inert)
        let combo = KeyCombo(.space, .command)
        #expect(hotkeys.conflicts(for: combo).isEmpty)
        inert.setSymbolicHotkeys([SymbolicHotkey(holding: combo)])
        #expect(hotkeys.conflicts(for: combo).first?.isSystemShortcut == true)
        #expect(throws: HotkeyError.self) { try hotkeys.register(combo, id: "launcher") {} }
        #expect((hotkeys.system as? InertHotkeySystem) === inert)
        inert.setSymbolicHotkeys([])
        try hotkeys.register(combo, id: "launcher") {}
        #expect(hotkeys.registered == ["launcher": combo])
    }

    @Test func registeringAnIDAgainReplacesItAndAFailureKeepsTheOldOne() throws {
        let hotkeys = HotkeyCenter(system: system)
        let first = KeyCombo(Key(name: "1")!, .control)
        let second = KeyCombo(Key(name: "2")!, .control)
        try hotkeys.register(first, id: "item") {}
        try hotkeys.register(second, id: "item") {}
        #expect(hotkeys.registered == ["item": second])
        #expect(system.registrations.count == 1)

        // The system refuses the next registration once; the old chord comes back.
        system.state.withLock { $0.failure = -9878 }
        #expect(throws: HotkeyError.registrationFailed(code: -9878)) {
            try hotkeys.register(KeyCombo(Key(name: "3")!, .control), id: "item") {}
        }
        #expect(hotkeys.registered == ["item": second])
        #expect(system.registrations.map(\.keyCode) == [UInt32(second.key.code)])

        // Carbon cannot use Function as a modifier.
        #expect(throws: HotkeyError.self) { try hotkeys.register(KeyCombo(.f, .function), id: "fn") {} }
        #expect(hotkeys.registered["fn"] == nil)
        hotkeys.unregisterAll()
        #expect(hotkeys.registered.isEmpty)
        #expect(system.registrations.isEmpty)
    }

    @Test func symbolicHotkeyEntriesAreParsed() {
        let entry: [String: Any] = [
            "kHISymbolicHotKeyCode": NSNumber(value: 49),
            "kHISymbolicHotKeyModifiers": NSNumber(value: 256 | 0x100000),
            "kHISymbolicHotKeyEnabled": NSNumber(value: true),
        ]
        #expect(
            CarbonHotkeySystem.symbolicHotkey(entry)
                == SymbolicHotkey(keyCode: 49, modifiers: CarbonModifiers.command, isEnabled: true))
        #expect(CarbonHotkeySystem.symbolicHotkey(["kHISymbolicHotKeyCode": NSNumber(value: 65535)]) == nil)
        #expect(SystemShortcutNames.owner(of: KeyCombo(.z, .control)) == "A macOS keyboard shortcut")
    }

    /// Makes a Carbon event in memory and decodes it. Nothing is posted to the system.
    @Test func theEventHandlerDecodesOnlyItsOwnPresses() throws {
        func event(signature: OSType, number: UInt32) throws -> EventRef {
            var event: EventRef?
            let created = CreateEvent(
                nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, EventAttributes(kEventAttributeNone),
                &event)
            #expect(created == noErr)
            let made = try #require(event)
            var id = EventHotKeyID(signature: signature, id: number)
            let set = SetEventParameter(
                made, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                MemoryLayout<EventHotKeyID>.size, &id)
            #expect(set == noErr)
            return made
        }
        let ours = try event(signature: CarbonHotkeySystem.signature, number: 7)
        let theirs = try event(signature: 0x4F54_4852, number: 7)
        defer {
            ReleaseEvent(ours)
            ReleaseEvent(theirs)
        }
        #expect(CarbonHotkeySystem.hotkeyNumber(in: ours) == 7)
        #expect(CarbonHotkeySystem.hotkeyNumber(in: theirs) == nil)
    }

    /// The one test that registers with macOS: an unlikely chord, unregistered before it returns.
    @Test func carbonRegistersAndUnregistersAnUnlikelyChord() throws {
        let hotkeys = HotkeyCenter(system: CarbonHotkeySystem())
        defer { hotkeys.unregisterAll() }
        let chord = KeyCombo(Key(name: "f19")!, [.control, .option, .shift, .command])
        #expect(hotkeys.conflicts(for: chord).isEmpty)
        try hotkeys.register(chord, id: "test.unlikely") {}
        #expect(hotkeys.registered == ["test.unlikely": chord])
        #expect(hotkeys.conflicts(for: chord) == [HotkeyConflict(owner: "test.unlikely", canOverride: true)])
        hotkeys.unregister(id: "test.unlikely")
        #expect(hotkeys.registered.isEmpty)
    }

    @Test func modifiersMapToCarbonBits() {
        #expect(CarbonModifiers.mask(for: [.command, .option], allowingFunction: false) == UInt32(cmdKey | optionKey))
        #expect(
            CarbonModifiers.mask(for: [.control, .shift], allowingFunction: false) == UInt32(controlKey | shiftKey))
        #expect(CarbonModifiers.mask(for: .function, allowingFunction: false) == nil)
        #expect(CarbonModifiers.mask(for: .function, allowingFunction: true) == CarbonModifiers.function)
    }

    @Test func theInertSystemRegistersNothing() throws {
        let hotkeys = HotkeyCenter(system: InertHotkeySystem())
        try hotkeys.register(KeyCombo(.space, .command), id: "launcher") {}
        #expect(hotkeys.registered.count == 1)
        #expect(hotkeys.conflicts(for: KeyCombo(.space, .command), excluding: "launcher").isEmpty)
    }
}
