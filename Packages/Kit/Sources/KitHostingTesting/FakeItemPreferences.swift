import Kit
import KitHosting

/// Item preferences in memory, the fallback choices included.
///
/// With a ``FakeFeatureDirectory``, turning a feature or command on or off also updates the
/// directory, and turning a feature on or off calls the registered feature's
/// ``Feature/activate()`` or ``Feature/deactivate()``, as the runtime does. Hotkeys follow the
/// contract: another item's binding is taken over, and a conflict that cannot be overridden throws.
@MainActor public final class FakeItemPreferences: ItemPreferences {
    public let changes = ChangeSignal()
    public private(set) var aliases: [ItemID: String] = [:]
    public private(set) var hotkeys: [ItemID: KeyCombo] = [:]
    public private(set) var favorites: [ItemID] = []
    public private(set) var fallbackChoices = FallbackChoices()

    /// The launcher hotkey, reported as a conflict that cannot be overridden. Default nil.
    public var launcherHotkey: KeyCombo?
    /// When set, ``setHotkey(_:for:)`` throws it for every combination, as when the system refuses.
    public var bindingFailure: HotkeyError?

    private let directory: FakeFeatureDirectory?
    private var featureSwitches: [String: Bool] = [:]
    private var disabledCommands: Set<ItemID> = []
    private var systemConflicts: [KeyCombo: [HotkeyConflict]] = [:]

    /// - Parameter directory: A directory to keep in step with the feature and command switches.
    public init(directory: FakeFeatureDirectory? = nil) {
        self.directory = directory
    }

    /// Makes ``hotkeyConflicts(for:excluding:)`` report a system shortcut for the combination.
    public func addConflict(_ conflict: HotkeyConflict, for combo: KeyCombo) {
        systemConflicts[combo, default: []].append(conflict)
    }

    /// Makes ``hotkeyConflicts(for:excluding:)`` report an enabled macOS shortcut, such as
    /// Spotlight's, for the combination.
    public func addSystemShortcut(_ combo: KeyCombo, owner: String = "Spotlight") {
        addConflict(HotkeyConflict(owner: owner, canOverride: false, isSystemShortcut: true), for: combo)
    }

    /// Removes the conflicts added for the combination, as when the user turns a macOS shortcut off.
    public func removeConflicts(for combo: KeyCombo) {
        systemConflicts[combo] = nil
    }

    public func setAlias(_ alias: String?, for id: ItemID) {
        aliases[id] = alias.flatMap { $0.isEmpty ? nil : $0 }
        changes.send()
    }

    public func setHotkey(_ combo: KeyCombo?, for id: ItemID) throws {
        if let combo {
            if let bindingFailure { throw bindingFailure }
            let blocking = hotkeyConflicts(for: combo, excluding: id).filter { !$0.canOverride }
            if !blocking.isEmpty { throw HotkeyError.conflict(blocking) }
            for (other, otherCombo) in hotkeys where otherCombo == combo && other != id {
                hotkeys[other] = nil
            }
        }
        hotkeys[id] = combo
        changes.send()
    }

    /// Reports system shortcuts added with ``addConflict(_:for:)``, the launcher hotkey, and other
    /// items' hotkeys, whose owner is the item's raw ID.
    public func hotkeyConflicts(for combo: KeyCombo, excluding id: ItemID?) -> [HotkeyConflict] {
        var conflicts = systemConflicts[combo] ?? []
        if combo == launcherHotkey { conflicts.append(HotkeyConflict(owner: "Launcher", canOverride: false)) }
        for (other, otherCombo) in hotkeys.sorted(by: { $0.key.rawValue < $1.key.rawValue })
        where otherCombo == combo && other != id {
            conflicts.append(HotkeyConflict(owner: other.rawValue, canOverride: true))
        }
        return conflicts
    }

    public func setFavorites(_ ids: [ItemID]) {
        var seen: Set<ItemID> = []
        favorites = ids.filter { seen.insert($0).inserted }
        changes.send()
    }

    public func setFallbackChoices(_ choices: FallbackChoices) {
        fallbackChoices = choices
        changes.send()
    }

    public func isEnabled(feature featureID: String) -> Bool {
        featureSwitches[featureID] ?? directory?.feature(featureID)?.isEnabled ?? false
    }

    public func setEnabled(_ enabled: Bool, feature featureID: String) async {
        featureSwitches[featureID] = enabled
        directory?.setEnabled(enabled, feature: featureID)
        if let feature = directory?.instance(featureID) {
            if enabled { await feature.activate() } else { await feature.deactivate() }
        }
        changes.send()
    }

    public func isEnabled(command id: ItemID) -> Bool {
        !disabledCommands.contains(id)
    }

    public func setEnabled(_ enabled: Bool, command id: ItemID) {
        if enabled { disabledCommands.remove(id) } else { disabledCommands.insert(id) }
        directory?.setEnabled(enabled, command: id)
        changes.send()
    }
}
