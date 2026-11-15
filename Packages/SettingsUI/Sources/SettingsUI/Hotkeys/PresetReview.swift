import Kit
import KitHosting

/// What applying a hotkey preset would change, shown before anything is bound.
struct PresetReview: Identifiable {
    /// One command in the preset.
    struct Binding: Identifiable {
        var id: ItemID
        var title: String
        var combo: KeyCombo
        /// The hotkey the command has now, if any.
        var current: KeyCombo?
        /// Other users of the combination. Those that cannot be overridden stop this binding.
        var conflicts: [HotkeyConflict]
        var conflictText: String

        /// True when the binding would be skipped.
        var isBlocked: Bool { conflicts.contains { !$0.canOverride } }
    }

    let preset: HotkeyPreset
    let bindings: [Binding]
    private let preferences: any ItemPreferences

    var id: String { preset.id }

    /// Bindings in the feature's command order. Preset keys that name no command are ignored.
    init(preset: HotkeyPreset, entry: FeatureEntry, context: SettingsContext) {
        self.preset = preset
        preferences = context.preferences
        let presetIDs = Set(entry.commands.compactMap { preset.bindings[$0.command.id] == nil ? nil : $0.id })
        bindings = entry.commands.compactMap { command in
            guard let combo = preset.bindings[command.command.id] else { return nil }
            // Commands of the same preset trade combinations among themselves; that is not a conflict.
            let conflicts = context.preferences.hotkeyConflicts(for: combo, excluding: command.id).filter { conflict in
                guard let owner = ItemID(rawValue: conflict.owner) else { return true }
                return !presetIDs.contains(owner)
            }
            let names = conflicts.map { context.describe($0) }
            return Binding(
                id: command.id, title: command.command.title, combo: combo,
                current: context.preferences.hotkeys[command.id], conflicts: conflicts,
                conflictText: names.joined(separator: ", "))
        }
    }

    /// True when every binding would apply cleanly.
    var isClean: Bool { bindings.allSatisfy { $0.conflicts.isEmpty } }

    /// Binds every binding that is not blocked. Returns the titles of those that failed or were
    /// skipped.
    func apply() -> [String] {
        var failures: [String] = []
        for binding in bindings {
            guard !binding.isBlocked else {
                failures.append(binding.title)
                continue
            }
            do {
                try preferences.setHotkey(binding.combo, for: binding.id)
            } catch {
                failures.append(binding.title)
            }
        }
        return failures
    }
}
