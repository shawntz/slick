import Kit
import Synchronization

/// Hotkeys in memory. Nothing is registered with the system; ``press(_:)`` plays the user pressing
/// one.
public final class FakeHotkeys: HotkeyService {
    private struct State {
        var registered: [String: KeyCombo] = [:]
        var handlers: [String: @MainActor @Sendable () -> Void] = [:]
        var conflicts: [KeyCombo: [HotkeyConflict]] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// Registered hotkeys by ID.
    public var registered: [String: KeyCombo] { state.withLock { $0.registered } }

    /// Makes ``conflicts(for:)`` report a conflict, and ``register(_:id:handler:)`` refuse the
    /// combination.
    public func addConflict(_ conflict: HotkeyConflict, for combo: KeyCombo) {
        state.withLock { $0.conflicts[combo, default: []].append(conflict) }
    }

    /// Makes ``conflicts(for:)`` report an enabled macOS shortcut, such as Spotlight's, for the
    /// combination. ``register(_:id:handler:)`` refuses it, as the live service does.
    public func addSystemShortcut(_ combo: KeyCombo, owner: String = "Spotlight") {
        addConflict(HotkeyConflict(owner: owner, canOverride: false, isSystemShortcut: true), for: combo)
    }

    /// Removes every conflict added for the combination, as when the user turns a macOS shortcut off.
    public func removeConflicts(for combo: KeyCombo) {
        state.withLock { $0.conflicts[combo] = nil }
    }

    /// Runs the handler registered under the ID, as if the user pressed the hotkey. Returns false when
    /// nothing is registered under it.
    @discardableResult
    public func press(_ id: String) async -> Bool {
        guard let handler = state.withLock({ $0.handlers[id] }) else { return false }
        await handler()
        return true
    }

    public func register(_ combo: KeyCombo, id: String, handler: @escaping @MainActor @Sendable () -> Void) throws {
        try state.withLock { state in
            if let conflicts = state.conflicts[combo], !conflicts.isEmpty { throw HotkeyError.conflict(conflicts) }
            state.registered[id] = combo
            state.handlers[id] = handler
        }
    }

    public func unregister(id: String) {
        state.withLock { state in
            state.registered[id] = nil
            state.handlers[id] = nil
        }
    }

    public func conflicts(for combo: KeyCombo) -> [HotkeyConflict] {
        state.withLock { $0.conflicts[combo] ?? [] }
    }
}
