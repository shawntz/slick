import CoreFoundation
import Darwin
import Foundation
import Kit
import Synchronization
import os

/// One of Spotlight's two keyboard shortcuts, by the number macOS stores it under in the
/// `com.apple.symbolichotkeys` domain.
nonisolated public enum SpotlightShortcut: Int, Hashable, Sendable, CaseIterable {
    /// Show Spotlight search, Command-Space on a new Mac.
    case search = 64
    /// Show Finder search window, Option-Command-Space on a new Mac.
    case finderSearch = 65

    /// What macOS uses when the domain has no entry for the shortcut: the character, the virtual
    /// key code and the modifier flags. Space, Space and Command for search, and Space, Space and
    /// Option-Command for the Finder search window.
    public var defaultParameters: [Int] {
        switch self {
        case .search: [32, 49, 1_048_576]
        case .finderSearch: [32, 49, 1_572_864]
        }
    }

    /// The name people know both shortcuts by: they sit under Spotlight in Keyboard Shortcuts.
    public var owner: String { "Spotlight" }

    /// The shortcut as Kit names it.
    public var systemShortcut: SystemShortcut { SystemShortcut(number: rawValue, owner: owner) }
}

/// Turns Spotlight's own keyboard shortcuts off and on, and says which of them uses a combination.
///
/// ``LiveSpotlightShortcutSwitch`` changes the Mac, and only the live launcher makes one.
/// ``InertSpotlightShortcutSwitch`` stands in for every other run and every test.
nonisolated public protocol SpotlightShortcutSwitch: Sendable {
    /// The Spotlight shortcut that is on and uses this virtual key code with these Carbon modifier
    /// bits, or nil. Only reads.
    func shortcut(keyCode: UInt16, modifiers: UInt32) -> SpotlightShortcut?

    /// Stores the shortcut's state, so it holds after a restart, and applies it now. True when both
    /// steps reported success. The caller reads the system's shortcuts again to check.
    @concurrent func setEnabled(_ enabled: Bool, _ shortcut: SpotlightShortcut) async -> Bool
}

/// Reads and changes the stored dictionary of the system's shortcuts. Pure: every function takes
/// the dictionary as it was read and returns what to write, so tests hand it dictionaries they
/// made and nothing reads the Mac's own settings.
nonisolated public enum SymbolicHotkeyPreferences {
    /// The preference domain of the system's keyboard shortcuts.
    public static let domain = "com.apple.symbolichotkeys"
    /// The key of the dictionary of every shortcut, by number.
    public static let key = "AppleSymbolicHotKeys"

    /// The dictionary with the shortcut's `enabled` set, ready to write back, or nil when it must
    /// not be written: what was read is not a dictionary, or the shortcut's entry is there but is
    /// not one. An entry that exists keeps its `value` and every other key. A missing entry gets
    /// what macOS uses by default, with `enabled` set. Every other entry stays as it was.
    public static func setting(_ enabled: Bool, _ shortcut: SpotlightShortcut, in stored: Any?) -> [String: Any]? {
        guard var dictionary = stored as? [String: Any] else { return nil }
        let name = String(shortcut.rawValue)
        if let existing = dictionary[name] {
            guard var entry = existing as? [String: Any] else { return nil }
            entry["enabled"] = enabled
            dictionary[name] = entry
        } else {
            dictionary[name] =
                [
                    "enabled": enabled,
                    "value": ["parameters": shortcut.defaultParameters, "type": "standard"] as [String: Any],
                ] as [String: Any]
        }
        return dictionary
    }

    /// The Spotlight shortcut that is on and uses the key code and Carbon modifiers, by the stored
    /// dictionary, or nil. A missing entry counts as macOS's default, which is on. Nil when what was
    /// read is not a dictionary, because then nothing could be written back either.
    public static func shortcut(keyCode: UInt16, modifiers: UInt32, in stored: Any?) -> SpotlightShortcut? {
        guard let dictionary = stored as? [String: Any] else { return nil }
        return SpotlightShortcut.allCases.first { shortcut in
            let entry = dictionary[String(shortcut.rawValue)]
            if entry != nil, !(entry is [String: Any]) { return false }
            let fields = entry as? [String: Any] ?? [:]
            if let enabled = fields["enabled"], !isTrue(enabled) { return false }
            let parameters = ((fields["value"] as? [String: Any])?["parameters"] as? [Any])?.compactMap(integer)
            let used = parameters ?? shortcut.defaultParameters
            guard used.count >= 3, let code = UInt16(exactly: used[1]) else { return false }
            return code == keyCode && carbonModifiers(eventFlags: used[2]) == modifiers
        }
    }

    /// Carbon's modifier bits for the event modifier flags the domain stores.
    public static func carbonModifiers(eventFlags flags: Int) -> UInt32 {
        var mask: UInt32 = 0
        if flags & (1 << 17) != 0 { mask |= CarbonModifiers.shift }
        if flags & (1 << 18) != 0 { mask |= CarbonModifiers.control }
        if flags & (1 << 19) != 0 { mask |= CarbonModifiers.option }
        if flags & (1 << 20) != 0 { mask |= CarbonModifiers.command }
        if flags & (1 << 23) != 0 { mask |= CarbonModifiers.function }
        return mask
    }

    private static func isTrue(_ value: Any) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    private static func integer(_ value: Any) -> Int? {
        if let int = value as? Int { return int }
        return (value as? NSNumber)?.intValue
    }
}

/// The live switch. It runs only in the live launcher, and only after the person asked: when they
/// continue past onboarding's hotkey step, or press Turn Off Spotlight's Shortcut or Turn It Back
/// On. Nothing in a test or another run mode makes one.
///
/// To change a shortcut it stores the change and applies it:
///
/// 1. It reads `AppleSymbolicHotKeys` of `com.apple.symbolichotkeys` for the current user and any
///    host, changes the one entry with ``SymbolicHotkeyPreferences/setting(_:_:in:)``, writes the
///    whole dictionary back and synchronizes. It writes nothing when what it read is not a
///    dictionary.
/// 2. It applies the change at once with the window server's `CGSSetSymbolicHotKeyEnabled`, found
///    with `dlsym` at run time, so nothing links against a private symbol. Without that symbol it
///    runs `activateSettings -u`, which makes the system read the stored shortcuts again.
///
/// When the second step fails, it writes back the dictionary it read, so the stored state and the
/// state in effect agree.
nonisolated public final class LiveSpotlightShortcutSwitch: SpotlightShortcutSwitch {
    /// The tool that makes the system read the stored shortcuts again.
    public static let activateSettings = URL(
        filePath: "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")

    private let processes: any ProcessService
    private let log = KitLog.logger(category: "platform.spotlight")

    /// - Parameter processes: Runs `activateSettings` when the window server's function is missing.
    public init(processes: any ProcessService) {
        self.processes = processes
    }

    public func shortcut(keyCode: UInt16, modifiers: UInt32) -> SpotlightShortcut? {
        SymbolicHotkeyPreferences.shortcut(keyCode: keyCode, modifiers: modifiers, in: Self.readStored())
    }

    @concurrent public func setEnabled(_ enabled: Bool, _ shortcut: SpotlightShortcut) async -> Bool {
        let stored = Self.readStored(fresh: true)
        guard let changed = SymbolicHotkeyPreferences.setting(enabled, shortcut, in: stored) else {
            log.error("symbolic hot keys are not a dictionary; nothing written")
            return false
        }
        guard Self.write(changed) else {
            log.error("could not store symbolic hot key \(shortcut.rawValue)")
            return false
        }
        if await apply(enabled, shortcut) { return true }
        log.error("could not apply symbolic hot key \(shortcut.rawValue); the stored dictionary is put back")
        if let stored = stored as? [String: Any] { _ = Self.write(stored) }
        return false
    }

    /// Applies the change now: through the window server when its function exists, otherwise by
    /// having the system read the stored shortcuts again.
    private func apply(_ enabled: Bool, _ shortcut: SpotlightShortcut) async -> Bool {
        if let setEnabled = WindowServerHotkeys.setEnabled {
            // On the main thread, where the app makes its other window server calls.
            let number = Int32(shortcut.rawValue)
            return MainThread.run { setEnabled(number, enabled) } == 0
        }
        let request = ProcessRequest(executable: Self.activateSettings, arguments: ["-u"], timeout: .seconds(10))
        guard let result = try? await processes.run(request) else { return false }
        return result.exitCode == 0
    }

    /// The whole dictionary of the system's shortcuts, as stored for the current user and any host.
    /// `fresh` synchronizes first, which reads the latest stored data, so a change the person made
    /// in System Settings since this process last read the domain is never written back over. Only
    /// a change asks for it; the read that names a conflict takes what the process has.
    private static func readStored(fresh: Bool = false) -> Any? {
        let domain = SymbolicHotkeyPreferences.domain as CFString
        if fresh { _ = CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) }
        return CFPreferencesCopyValue(
            SymbolicHotkeyPreferences.key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    /// Writes the whole dictionary back and synchronizes. True when the synchronization succeeded.
    private static func write(_ dictionary: [String: Any]) -> Bool {
        let domain = SymbolicHotkeyPreferences.domain as CFString
        CFPreferencesSetValue(
            SymbolicHotkeyPreferences.key as CFString, dictionary as CFDictionary, domain, kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost)
        return CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}

/// The window server's function that turns a symbolic hot key on or off, looked up once at run
/// time. Nil when this macOS does not have it.
nonisolated enum WindowServerHotkeys {
    /// `CGError CGSSetSymbolicHotKeyEnabled(int32_t hotKey, bool enabled)`.
    typealias SetEnabled = @convention(c) (Int32, Bool) -> Int32

    static let setEnabled: SetEnabled? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetSymbolicHotKeyEnabled") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SetEnabled.self)
    }()
}

/// A switch that changes nothing on the Mac, for every run but the live launcher. It works on the
/// macOS shortcuts an ``InertHotkeySystem`` plays: Spotlight's on their default keys, Command-Space
/// for search and Option-Command-Space for the Finder search window. Turning one off turns off the
/// played shortcut, so a scenario can walk onboarding's Continue to the end.
nonisolated public final class InertSpotlightShortcutSwitch: SpotlightShortcutSwitch {
    private let system: InertHotkeySystem
    private let state = Mutex(State())

    private struct State {
        var refusesChanges = false
        var changes: [(enabled: Bool, shortcut: SpotlightShortcut)] = []
    }

    public init(system: InertHotkeySystem) {
        self.system = system
    }

    /// True makes every change fail and change nothing, as when the system does not take it.
    public var refusesChanges: Bool {
        get { state.withLock { $0.refusesChanges } }
        set { state.withLock { $0.refusesChanges = newValue } }
    }

    /// Every change asked for, oldest first.
    public var changes: [(enabled: Bool, shortcut: SpotlightShortcut)] { state.withLock { $0.changes } }

    public func shortcut(keyCode: UInt16, modifiers: UInt32) -> SpotlightShortcut? {
        guard let shortcut = Self.played(keyCode: keyCode, modifiers: modifiers) else { return nil }
        let isOn = system.symbolicHotkeys().contains {
            $0.isEnabled && $0.keyCode == keyCode && $0.modifiers == modifiers
        }
        return isOn ? shortcut : nil
    }

    @concurrent public func setEnabled(_ enabled: Bool, _ shortcut: SpotlightShortcut) async -> Bool {
        let refuses = state.withLock { state -> Bool in
            state.changes.append((enabled, shortcut))
            return state.refusesChanges
        }
        guard !refuses else { return false }
        let parameters = shortcut.defaultParameters
        let keyCode = UInt16(parameters[1])
        let modifiers = SymbolicHotkeyPreferences.carbonModifiers(eventFlags: parameters[2])
        var played = system.symbolicHotkeys()
        var found = false
        for index in played.indices where played[index].keyCode == keyCode && played[index].modifiers == modifiers {
            played[index].isEnabled = enabled
            found = true
        }
        if !found { played.append(SymbolicHotkey(keyCode: keyCode, modifiers: modifiers, isEnabled: enabled)) }
        system.setSymbolicHotkeys(played)
        return true
    }

    /// The Spotlight shortcut whose default keys these are.
    private static func played(keyCode: UInt16, modifiers: UInt32) -> SpotlightShortcut? {
        SpotlightShortcut.allCases.first { shortcut in
            let parameters = shortcut.defaultParameters
            return UInt16(parameters[1]) == keyCode
                && SymbolicHotkeyPreferences.carbonModifiers(eventFlags: parameters[2]) == modifiers
        }
    }
}
