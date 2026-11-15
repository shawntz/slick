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

/// The live hotkey service: bookkeeping and conflict checks on top of a ``HotkeySystem``.
///
/// A combination conflicts with an enabled system shortcut that uses it, which Slick cannot take
/// over, and with any of Slick's own registrations under another ID, which it can after asking.
/// ``register(_:id:handler:)`` refuses either kind; the host unregisters the other item first.
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

    private let system: any HotkeySystem
    private let state = Mutex(State())

    public init(system: any HotkeySystem) {
        self.system = system
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
        if let mask = CarbonModifiers.mask(for: combo.modifiers, allowingFunction: true) {
            let usedBySystem = system.symbolicHotkeys().contains {
                $0.isEnabled && $0.keyCode == combo.key.code && $0.modifiers == mask
            }
            if usedBySystem {
                conflicts.append(HotkeyConflict(owner: SystemShortcutNames.owner(of: combo), canOverride: false))
            }
        }
        let own = state.withLock { state in
            state.entries.filter { $0.key != id && $0.value.combo == combo }.keys.sorted()
        }
        conflicts += own.map { HotkeyConflict(owner: $0, canOverride: true) }
        return conflicts
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
/// than `live`, where hardware key events are ignored.
nonisolated public final class InertHotkeySystem: HotkeySystem {
    private let next = Atomic<UInt>(0)

    public init() {}

    public func register(keyCode: UInt32, modifiers: UInt32, number: UInt32) throws -> HotkeyToken {
        HotkeyToken(raw: next.add(1, ordering: .relaxed).newValue)
    }

    public func unregister(_ token: HotkeyToken) {}

    public func symbolicHotkeys() -> [SymbolicHotkey] { [] }

    public func setPressHandler(_ handler: @escaping @MainActor @Sendable (UInt32) -> Void) {}
}
