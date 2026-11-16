import Foundation
import Kit
import Synchronization

/// What the hotkey center needs from the system. ``CarbonHotkeySystem`` is the live one.
nonisolated public protocol HotkeySystem: Sendable {
    /// Registers a chord. `number` comes back to the press handler when the user presses it.
    /// Throws ``HotkeyError/registrationFailed(code:)`` when the system refuses.
    func register(keyCode: UInt32, modifiers: UInt32, number: UInt32) throws -> HotkeyToken

    /// Removes a chord registered earlier.
    func unregister(_ token: HotkeyToken)

    /// The system's own keyboard shortcuts. Never registers anything.
    func symbolicHotkeys() -> [SymbolicHotkey]

    /// Sets what runs, on the main actor, when a registered chord is pressed.
    func setPressHandler(_ handler: @escaping @MainActor @Sendable (UInt32) -> Void)
}

/// A registration the system handed out.
nonisolated public struct HotkeyToken: Hashable, Sendable {
    /// The system's handle, as bits.
    public let raw: UInt

    public init(raw: UInt) {
        self.raw = raw
    }
}

/// One of the system's keyboard shortcuts.
nonisolated public struct SymbolicHotkey: Hashable, Sendable {
    /// The virtual key code.
    public var keyCode: UInt16
    /// Carbon modifier bits, limited to ``CarbonModifiers/relevantMask``.
    public var modifiers: UInt32
    public var isEnabled: Bool

    public init(keyCode: UInt16, modifiers: UInt32, isEnabled: Bool) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isEnabled = isEnabled
    }
}

extension SymbolicHotkey {
    /// An enabled system shortcut on a combination, as a scenario plays one.
    public init(holding combo: KeyCombo) {
        let mask = CarbonModifiers.mask(for: combo.modifiers, allowingFunction: true) ?? 0
        self.init(keyCode: combo.key.code, modifiers: mask, isEnabled: true)
    }
}

/// The live hotkey service: bookkeeping and conflict checks on top of a ``HotkeySystem``.
///
/// A combination conflicts with an enabled system shortcut that uses it, which Slick never
/// registers over and which is marked ``HotkeyConflict/isSystemShortcut``, and with any of Slick's
/// own registrations under another ID, which it can take after asking. ``register(_:id:handler:)``
/// refuses either kind; the host unregisters the other item first.
///
/// A system shortcut that is one of Spotlight's own two, as the ``SpotlightShortcutSwitch`` reads
/// it, is marked ``HotkeyConflict/canTurnOff``, and ``turnOffSystemShortcut(for:)`` turns it off
/// through that switch, then reads the system's shortcuts again to check that the combination is
/// free. Every other system shortcut is never touched.
/// Handlers run on the main actor. Call the service from the main actor: the Carbon calls run on
/// the main thread, and a call from elsewhere waits for it.
nonisolated public final class HotkeyCenter: HotkeyService {
    private struct Entry {
        var combo: KeyCombo
        var number: UInt32
        var token: HotkeyToken
        var handler: @MainActor @Sendable () -> Void
    }

    private struct State {
        var entries: [String: Entry] = [:]
        var nextNumber: UInt32 = 1
    }

    /// The system the registrations go to. A scenario reaches the inert one through it to play a
    /// macOS shortcut that uses a combination.
    public let system: any HotkeySystem
    /// What turns Spotlight's shortcuts off and on. Only the live launcher passes the live one.
    public let shortcuts: (any SpotlightShortcutSwitch)?
    private let state = Mutex(State())

    /// - Parameters:
    ///   - system: Where the registrations go.
    ///   - shortcuts: What turns Spotlight's shortcuts off and on. Nil makes the inert switch over an
    ///     ``InertHotkeySystem`` and no switch over any other system, so no conflict can be turned
    ///     off.
    public init(system: any HotkeySystem, shortcuts: (any SpotlightShortcutSwitch)? = nil) {
        self.system = system
        self.shortcuts = shortcuts ?? (system as? InertHotkeySystem).map(InertSpotlightShortcutSwitch.init(system:))
        system.setPressHandler { [weak self] number in
            self?.dispatch(number: number)
        }
    }

    /// Every registration by ID.
    public var registered: [String: KeyCombo] {
        state.withLock { $0.entries.mapValues(\.combo) }
    }

    public func register(_ combo: KeyCombo, id: String, handler: @escaping @MainActor @Sendable () -> Void) throws {
        guard let modifiers = CarbonModifiers.mask(for: combo.modifiers, allowingFunction: false) else {
            // Carbon cannot register the Function key as a modifier.
            throw HotkeyError.registrationFailed(code: Int32(paramErr))
        }
        let conflicts = conflicts(for: combo, excluding: id)
        if !conflicts.isEmpty { throw HotkeyError.conflict(conflicts) }

        let (number, previous) = state.withLock { state -> (UInt32, Entry?) in
            defer { state.nextNumber &+= 1 }
            return (state.nextNumber, state.entries.removeValue(forKey: id))
        }
        if let previous { system.unregister(previous.token) }
        let token: HotkeyToken
        do {
            token = try system.register(keyCode: UInt32(combo.key.code), modifiers: modifiers, number: number)
        } catch {
            if let previous { restore(previous, id: id) }
            throw error
        }
        state.withLock { $0.entries[id] = Entry(combo: combo, number: number, token: token, handler: handler) }
    }

    public func unregister(id: String) {
        guard let entry = state.withLock({ $0.entries.removeValue(forKey: id) }) else { return }
        system.unregister(entry.token)
    }

    /// Removes every registration, such as when the app quits.
    public func unregisterAll() {
        let entries = state.withLock { state -> [Entry] in
            defer { state.entries = [:] }
            return Array(state.entries.values)
        }
        for entry in entries {
            system.unregister(entry.token)
        }
    }

    public func conflicts(for combo: KeyCombo) -> [HotkeyConflict] {
        conflicts(for: combo, excluding: nil)
    }

    /// The conflicts for a combination, leaving out the registration under `id`.
    public func conflicts(for combo: KeyCombo, excluding id: String?) -> [HotkeyConflict] {
        var conflicts: [HotkeyConflict] = []
        if let mask = CarbonModifiers.mask(for: combo.modifiers, allowingFunction: true),
            usedBySystem(combo, mask: mask)
        {
            if let spotlight = shortcuts?.shortcut(keyCode: combo.key.code, modifiers: mask) {
                conflicts.append(
                    HotkeyConflict(owner: spotlight.owner, canOverride: false, isSystemShortcut: true, canTurnOff: true)
                )
            } else {
                conflicts.append(
                    HotkeyConflict(
                        owner: SystemShortcutNames.owner(of: combo), canOverride: false, isSystemShortcut: true))
            }
        }
        let own = state.withLock { state in
            state.entries.filter { $0.key != id && $0.value.combo == combo }.keys.sorted()
        }
        conflicts += own.map { HotkeyConflict(owner: $0, canOverride: true) }
        return conflicts
    }

    /// Turns off the Spotlight shortcut that uses the combination, then reads the system's
    /// shortcuts again. Returns the shortcut when the combination is free afterwards. Returns nil
    /// without changing anything when no Spotlight shortcut that is on uses it, which leaves every
    /// other macOS shortcut alone, and nil when the switch failed or the combination is still taken.
    @concurrent public func turnOffSystemShortcut(for combo: KeyCombo) async -> SystemShortcut? {
        guard let shortcuts, let mask = CarbonModifiers.mask(for: combo.modifiers, allowingFunction: true),
            usedBySystem(combo, mask: mask),
            let spotlight = shortcuts.shortcut(keyCode: combo.key.code, modifiers: mask)
        else { return nil }
        guard await shortcuts.setEnabled(false, spotlight) else { return nil }
        return usedBySystem(combo, mask: mask) ? nil : spotlight.systemShortcut
    }

    /// Turns a Spotlight shortcut back on, in the same two steps that turned it off. True when both
    /// reported success. Any other shortcut is never touched.
    @concurrent public func turnOnSystemShortcut(_ shortcut: SystemShortcut) async -> Bool {
        guard let shortcuts, let spotlight = SpotlightShortcut(rawValue: shortcut.number) else { return false }
        return await shortcuts.setEnabled(true, spotlight)
    }

    /// True when an enabled macOS shortcut uses the key with these Carbon modifiers, as the system
    /// reports its shortcuts now.
    private func usedBySystem(_ combo: KeyCombo, mask: UInt32) -> Bool {
        system.symbolicHotkeys().contains { $0.isEnabled && $0.keyCode == combo.key.code && $0.modifiers == mask }
    }

    /// Runs the handler of the registration with this number. The system's press handler calls
    /// it; tests call it to play a press.
    @MainActor public func dispatch(number: UInt32) {
        let handler = state.withLock { state in
            state.entries.values.first { $0.number == number }?.handler
        }
        handler?()
    }

    /// The number a registration got, for tests that play a press.
    public func number(for id: String) -> UInt32? {
        state.withLock { $0.entries[id]?.number }
    }

    /// Puts back a registration that a failed replacement removed. Best effort.
    private func restore(_ entry: Entry, id: String) {
        guard let modifiers = CarbonModifiers.mask(for: entry.combo.modifiers, allowingFunction: false),
            let token = try? system.register(
                keyCode: UInt32(entry.combo.key.code), modifiers: modifiers, number: entry.number)
        else { return }
        var restored = entry
        restored.token = token
        state.withLock { $0.entries[id] = restored }
    }
}

/// Carbon's modifier bits.
nonisolated public enum CarbonModifiers {
    public static let command: UInt32 = 1 << 8
    public static let shift: UInt32 = 1 << 9
    public static let option: UInt32 = 1 << 11
    public static let control: UInt32 = 1 << 12
    /// Carbon's Function key bit, which symbolic hotkeys may carry.
    public static let function: UInt32 = 1 << 17
    /// The bits two combinations are compared by.
    public static let relevantMask: UInt32 = command | shift | option | control | function

    /// The Carbon bits for Kit's modifiers, or nil when they include Function and that is not
    /// allowed.
    public static func mask(for modifiers: KeyModifiers, allowingFunction: Bool) -> UInt32? {
        if modifiers.contains(.function) && !allowingFunction { return nil }
        var mask: UInt32 = 0
        if modifiers.contains(.command) { mask |= command }
        if modifiers.contains(.shift) { mask |= shift }
        if modifiers.contains(.option) { mask |= option }
        if modifiers.contains(.control) { mask |= control }
        if modifiers.contains(.function) { mask |= function }
        return mask
    }
}

/// Names for the system shortcuts people meet most, by their default combinations.
/// `CopySymbolicHotKeys` reports combinations without names, so a combination the user moved to
/// another action may get the wrong name; the fallback is generic.
nonisolated public enum SystemShortcutNames {
    private static let known: [KeyCombo: String] = [
        KeyCombo(.space, .command): "Spotlight",
        KeyCombo(.space, [.command, .option]): "Finder search window",
        KeyCombo(.space, .control): "Select the previous input source",
        KeyCombo(.space, [.control, .option]): "Select the next input source",
        KeyCombo(Key(code: 0x14), [.command, .shift]): "Screenshot",
        KeyCombo(Key(code: 0x15), [.command, .shift]): "Screenshot of an area",
        KeyCombo(Key(code: 0x17), [.command, .shift]): "Screenshot options",
        KeyCombo(.upArrow, .control): "Mission Control",
        KeyCombo(.downArrow, .control): "Application windows",
        KeyCombo(.leftArrow, .control): "Move left a space",
        KeyCombo(.rightArrow, .control): "Move right a space",
    ]

    /// The likely owner of a system shortcut.
    public static func owner(of combo: KeyCombo) -> String {
        known[combo] ?? "A macOS keyboard shortcut"
    }
}

/// A hotkey system that registers nothing with macOS and never fires, for run environments other
/// than `live`, where hardware key events are ignored. It reports no system shortcuts until a
/// scenario plays some with ``setSymbolicHotkeys(_:)``.
nonisolated public final class InertHotkeySystem: HotkeySystem {
    private let next = Atomic<UInt>(0)
    private let symbolic = Mutex<[SymbolicHotkey]>([])

    public init() {}

    public func register(keyCode: UInt32, modifiers: UInt32, number: UInt32) throws -> HotkeyToken {
        HotkeyToken(raw: next.add(1, ordering: .relaxed).newValue)
    }

    public func unregister(_ token: HotkeyToken) {}

    public func symbolicHotkeys() -> [SymbolicHotkey] { symbolic.withLock { $0 } }

    /// Plays macOS shortcuts that hold combinations, as Spotlight holds Command-Space on a new Mac.
    public func setSymbolicHotkeys(_ hotkeys: [SymbolicHotkey]) {
        symbolic.withLock { $0 = hotkeys }
    }

    public func setPressHandler(_ handler: @escaping @MainActor @Sendable (UInt32) -> Void) {}
}
