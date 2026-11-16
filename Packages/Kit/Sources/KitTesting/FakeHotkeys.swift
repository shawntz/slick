import Kit
import Synchronization

/// Hotkeys in memory. Nothing is registered with the system; ``press(_:)`` plays the user pressing
/// one.
public final class FakeHotkeys: HotkeyService {
    private struct State {
        var registered: [String: KeyCombo] = [:]
        var handlers: [String: @MainActor @Sendable () -> Void] = [:]
        var conflicts: [KeyCombo: [HotkeyConflict]] = [:]
        /// Shortcuts turned off through the service, by combination.
        var turnedOff: [KeyCombo: (conflict: HotkeyConflict, shortcut: SystemShortcut)] = [:]
        var turnOffRequests: [KeyCombo] = []
        var turnOnRequests: [SystemShortcut] = []
        var turnOffFails = false
        var numbers: [KeyCombo: Int] = [:]
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
    /// combination. ``register(_:id:handler:)`` refuses it, as the live service does. With
    /// `canTurnOff`, ``turnOffSystemShortcut(for:)`` can turn it off, as the live service can for
    /// Spotlight's own shortcuts; `number` is the system's number it reports then.
    public func addSystemShortcut(
        _ combo: KeyCombo, owner: String = "Spotlight", canTurnOff: Bool = false, number: Int = 64
    ) {
        addConflict(
            HotkeyConflict(owner: owner, canOverride: false, isSystemShortcut: true, canTurnOff: canTurnOff),
            for: combo)
        if canTurnOff {
            state.withLock {
                $0.numbers[combo] = number
            }
        }
    }

    /// True makes every ``turnOffSystemShortcut(for:)`` fail and change nothing, as when the system
    /// does not take the change.
    public var turnOffFails: Bool {
        get { state.withLock { $0.turnOffFails } }
        set { state.withLock { $0.turnOffFails = newValue } }
    }

    /// Every combination ``turnOffSystemShortcut(for:)`` was asked about, in order.
    public var turnOffRequests: [KeyCombo] { state.withLock { $0.turnOffRequests } }

    /// Every shortcut ``turnOnSystemShortcut(_:)`` was asked to turn on, in order.
    public var turnOnRequests: [SystemShortcut] { state.withLock { $0.turnOnRequests } }

    /// The shortcuts turned off now, by the combination they used.
    public var turnedOff: [KeyCombo: SystemShortcut] { state.withLock { $0.turnedOff.mapValues(\.shortcut) } }

    /// Turns off the shortcut on the combination when it was added with `canTurnOff`, unless
    /// ``turnOffFails``: its conflict goes away, as when the system reads the shortcut off.
    @concurrent public func turnOffSystemShortcut(for combo: KeyCombo) async -> SystemShortcut? {
        state.withLock { state -> SystemShortcut? in
            state.turnOffRequests.append(combo)
            guard !state.turnOffFails,
                let index = state.conflicts[combo]?.firstIndex(where: { $0.isSystemShortcut && $0.canTurnOff }),
                let conflict = state.conflicts[combo]?.remove(at: index)
            else { return nil }
            if state.conflicts[combo]?.isEmpty == true { state.conflicts[combo] = nil }
            let shortcut = SystemShortcut(number: state.numbers[combo] ?? 64, owner: conflict.owner)
            state.turnedOff[combo] = (conflict, shortcut)
            return shortcut
        }
    }

    /// Turns a shortcut this fake turned off back on: its conflict comes back.
    @concurrent public func turnOnSystemShortcut(_ shortcut: SystemShortcut) async -> Bool {
        state.withLock { state -> Bool in
            state.turnOnRequests.append(shortcut)
            guard let (combo, entry) = state.turnedOff.first(where: { $0.value.shortcut == shortcut }) else {
                return false
            }
            state.turnedOff[combo] = nil
            state.conflicts[combo, default: []].append(entry.conflict)
            return true
        }
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
