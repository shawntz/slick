import Kit
import Observation

/// Where a recorded hotkey goes: the launcher hotkey, a command's hotkey or a feature's own
/// hotkey setting.
struct HotkeyTarget {
    /// What the recorder sets, for VoiceOver: "Launcher hotkey" or a command's title.
    var title: String
    /// The current combination, or nil.
    var read: @MainActor () -> KeyCombo?
    /// Everything that already uses a combination, other than this target.
    var conflicts: @MainActor (KeyCombo) -> [HotkeyConflict]
    /// Stores a combination, or nil to clear it. `replacing` lists the conflicts the user agreed to
    /// take the combination from. Throws when the system or the host refuses.
    var write: @MainActor (KeyCombo?, _ replacing: [HotkeyConflict]) throws -> Void
    /// True stores a combination that a macOS shortcut holds, instead of refusing it, because the
    /// target waits until the user turns that shortcut off. Only the launcher hotkey does.
    var waitsForSystemShortcuts = false
}

/// A hotkey recorder's state and rules, apart from the control that draws it.
///
/// The control calls ``beginRecording()`` when it takes focus, ``handle(key:modifiers:)`` for each
/// key press it receives from its own window, and ``endRecording()`` when it loses focus. Nothing
/// here listens to the system's key events.
///
/// Rules: a combination needs Command, Option or Control, unless its key is F1 to F20. Escape stops
/// recording, Delete clears the hotkey, and Tab moves focus on. A combination that something else
/// uses is not stored until the user agrees to take it over; one that cannot be taken over, such as
/// the launcher hotkey, is refused with the owner's name. A target that waits for system shortcuts
/// stores a combination a macOS shortcut holds and names the holder.
@Observable final class HotkeyRecorderModel {
    /// What the recorder shows.
    enum State: Equatable {
        /// Shows the stored combination.
        case idle
        /// Waiting for a combination. `held` shows modifiers held down so far.
        case recording(held: KeyModifiers)
        /// The combination is in use by things the user may take it from. Waiting for Replace or
        /// Cancel.
        case review(KeyCombo, [HotkeyConflict])
        /// The combination is in use by something that cannot give it up.
        case blocked(KeyCombo, [HotkeyConflict])
        /// The combination is stored, but macOS shortcuts hold it, so it works once they are off.
        case held(KeyCombo, [HotkeyConflict])
        /// The last key press was not a valid hotkey, or storing it failed.
        case message(String)
    }

    /// What one key press means to the recorder.
    enum Press: Equatable {
        case record(KeyCombo)
        case clear
        case cancel
        /// Tab or Shift-Tab: let the window move focus.
        case passThrough
        case reject(String)
    }

    /// Modifiers a combination needs at least one of, unless its key is a function key.
    static let requiredModifiers: KeyModifiers = [.command, .option, .control]
    /// Modifiers a hotkey can carry. The Fn flag that macOS sets on arrows and function keys is
    /// dropped.
    static let hotkeyModifiers: KeyModifiers = [.command, .option, .control, .shift]
    static let functionKeys: Set<Key> = Set((1...20).compactMap { Key(name: "f\($0)") })

    private(set) var state: State = .idle
    @ObservationIgnored let target: HotkeyTarget
    @ObservationIgnored private let describe: (HotkeyConflict) -> String
    private let revision = Revision()

    /// - Parameter describe: How a conflict's owner reads, such as a command's title for its ID.
    init(target: HotkeyTarget, describe: @escaping (HotkeyConflict) -> String = { $0.owner }) {
        self.target = target
        self.describe = describe
    }

    /// The stored combination.
    var combo: KeyCombo? {
        revision.track()
        return target.read()
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    /// Reads the stored value again, after it changed elsewhere.
    func refresh() {
        revision.bump()
    }

    // MARK: Recording

    func beginRecording() {
        state = .recording(held: [])
    }

    /// Stops recording. A review or message stays until answered.
    func endRecording() {
        if isRecording { state = .idle }
    }

    /// Shows the modifiers held while recording.
    func modifiersChanged(_ modifiers: KeyModifiers) {
        guard isRecording else { return }
        state = .recording(held: modifiers.intersection(Self.hotkeyModifiers))
    }

    /// Handles one key press while recording. Returns false when the press is not for the recorder,
    /// such as Tab, so the window can use it.
    @discardableResult
    func handle(key: Key, modifiers: KeyModifiers) -> Bool {
        guard isRecording else { return false }
        switch Self.classify(key: key, modifiers: modifiers) {
        case .passThrough:
            return false
        case .cancel:
            state = .idle
        case .clear:
            state = .idle
            store(nil, replacing: [])
        case .reject(let text):
            state = .message(text)
        case .record(let combo):
            propose(combo)
        }
        return true
    }

    /// Proposes a combination as if it was typed: stores it, or asks first when something uses it.
    func propose(_ combo: KeyCombo) {
        if combo == target.read() {
            state = .idle
            return
        }
        let conflicts = target.conflicts(combo)
        let held = heldBy(conflicts)
        let blocking = conflicts.filter { !$0.canOverride && !held.contains($0) }
        let others = conflicts.filter(\.canOverride)
        if !blocking.isEmpty {
            state = .blocked(combo, blocking)
        } else if !others.isEmpty {
            state = .review(combo, others)
        } else {
            state = .idle
            store(combo, replacing: [])
            if state == .idle && !held.isEmpty { state = .held(combo, held) }
        }
    }

    /// Takes the combination under review from its owners.
    func confirmReplace() {
        guard case .review(let combo, let conflicts) = state else { return }
        let held = heldBy(target.conflicts(combo))
        state = .idle
        store(combo, replacing: conflicts)
        if state == .idle && !held.isEmpty { state = .held(combo, held) }
    }

    /// The macOS shortcuts among the conflicts that this target may wait behind.
    private func heldBy(_ conflicts: [HotkeyConflict]) -> [HotkeyConflict] {
        target.waitsForSystemShortcuts ? conflicts.filter(\.isSystemShortcut) : []
    }

    /// Drops a review, a refusal or a message, keeping the stored combination.
    func dismiss() {
        state = .idle
    }

    /// Removes the stored combination.
    func clear() {
        state = .idle
        store(nil, replacing: [])
    }

    private func store(_ combo: KeyCombo?, replacing: [HotkeyConflict]) {
        do {
            try target.write(combo, replacing)
        } catch HotkeyError.conflict(let conflicts) {
            if let combo {
                state = .blocked(combo, conflicts)
            } else {
                state = .message("The hotkey could not be removed.")
            }
        } catch HotkeyError.registrationFailed {
            state = .message("macOS refused this hotkey. Try another combination.")
        } catch {
            state = .message(ErrorText.title(error, fallback: "The hotkey could not be saved."))
        }
        revision.bump()
    }

    // MARK: Text

    /// The owners of a list of conflicts, joined for a sentence: "Spotlight and Lock Screen".
    func owners(_ conflicts: [HotkeyConflict]) -> String {
        let names = conflicts.map(describe)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    /// The line under the recorder, or nil.
    var note: String? {
        switch state {
        case .idle, .recording: nil
        case .review(let combo, let conflicts):
            "\(owners(conflicts)) uses \(combo.displayString). Replace it?"
        case .blocked(let combo, let conflicts):
            "\(owners(conflicts)) uses \(combo.displayString) and keeps it. Choose other keys."
        case .held(let combo, let conflicts):
            "\(owners(conflicts)) already uses \(combo.displayString). \(Brand.name) can use it after you turn off that shortcut in System Settings."
        case .message(let text): text
        }
    }

    /// What the control shows.
    var displayText: String {
        if case .recording(let held) = state {
            return held.isEmpty ? "Type a shortcut" : held.symbols
        }
        return combo?.displayString ?? "Record Shortcut"
    }

    // MARK: Rules

    /// What a key press means, by the rules above.
    static func classify(key: Key, modifiers raw: KeyModifiers) -> Press {
        let modifiers = raw.intersection(hotkeyModifiers)
        if modifiers.isDisjoint(with: requiredModifiers) {
            if key == .tab { return .passThrough }
            if modifiers.isEmpty {
                if key == .escape { return .cancel }
                if key == .delete || key == .forwardDelete { return .clear }
            }
            if !functionKeys.contains(key) {
                return .reject("Add Command, Option or Control. Only F1 to F20 work alone.")
            }
        }
        return .record(KeyCombo(key, modifiers))
    }
}
