import Foundation
import Kit
import KitHosting
import KitStorage
import os

/// The app's ``ItemPreferences``: aliases, hotkeys, favorites and switches, kept in one JSON file.
///
/// Reads are in-memory lookups. Every change is written atomically off the main thread; writes are
/// coalesced, so a burst of changes writes the file once or twice. Item hotkeys are bound through
/// Kit's ``HotkeyService`` while their item can run: a command that exists and is on, or any other
/// item. A command that disappears keeps its alias and hotkey for ``missingCommandGrace``, in case
/// it comes back, as a script does after a checkout.
@MainActor public final class HostPreferences: ItemPreferences {
    /// How long a missing command keeps its alias and hotkey.
    public static let missingCommandGrace: TimeInterval = 30 * 24 * 60 * 60

    public let changes = ChangeSignal()
    public private(set) var aliases: [ItemID: String] = [:]
    public private(set) var hotkeys: [ItemID: KeyCombo] = [:]
    public private(set) var favorites: [ItemID] = []
    /// The user's fallback switches and order. Empty until the user changes a fallback.
    public private(set) var fallbackChoices = FallbackChoices()

    /// The file the preferences live in.
    public nonisolated let fileURL: URL

    weak var runtime: FeatureRuntime?
    private var featureSwitches: [String: Bool] = [:]
    private var disabledCommands: Set<ItemID> = []
    private var missingSince: [ItemID: Date] = [:]
    private var suppressed: Set<String> = []
    private var filterSelections: [String: String] = [:]
    private var bound: [ItemID: KeyCombo] = [:]
    private let hotkeyService: any HotkeyService
    private let general: FeatureSettings
    private let clock: any ClockService
    private let store: JSONFileStore<PreferencesFile>
    private var pending: PreferencesFile?
    private var writer: Task<Void, Never>?
    private let log = KitLog.logger(category: "host.preferences")

    init(file: URL, hotkeys: any HotkeyService, settings: any SettingsService, clock: any ClockService) {
        fileURL = file
        hotkeyService = hotkeys
        general = HostSettings.settings(settings)
        self.clock = clock
        store = JSONFileStore(url: file)
    }

    /// Reads the file off the main thread. A missing file means defaults; an unreadable one is
    /// logged and left alone until the next change overwrites it.
    public func load() async {
        let file: PreferencesFile
        do {
            file = try await store.load() ?? PreferencesFile()
        } catch {
            log.error("preferences could not be read: \(error.localizedDescription, privacy: .public)")
            file = PreferencesFile()
        }
        apply(file)
        changes.send()
    }

    /// Returns once every change so far is on disk.
    public func flush() async {
        while let writer {
            await writer.value
        }
    }

    // MARK: Aliases

    public func setAlias(_ alias: String?, for id: ItemID) {
        let trimmed = alias?.trimmingCharacters(in: .whitespaces)
        aliases[id] = (trimmed?.isEmpty ?? true) ? nil : trimmed
        didChange()
    }

    // MARK: Hotkeys

    public func setHotkey(_ combo: KeyCombo?, for id: ItemID) throws {
        guard let combo else {
            unbind(id)
            hotkeys[id] = nil
            didChange()
            return
        }
        let blocking = hotkeyConflicts(for: combo, excluding: id).filter { !$0.canOverride }
        if !blocking.isEmpty { throw HotkeyError.conflict(blocking) }
        let others = hotkeys.filter { $0.value == combo && $0.key != id }.map(\.key)
        for other in others { unbind(other) }
        let previous = hotkeys[id]
        unbind(id)
        if canBind(id) {
            do {
                try bind(id, combo)
            } catch {
                // Nothing is stored when it throws: give everyone their old binding back.
                for other in others { try? bind(other, combo) }
                if let previous { try? bind(id, previous) }
                throw error
            }
        }
        for other in others { hotkeys[other] = nil }
        hotkeys[id] = combo
        didChange()
    }

    public func hotkeyConflicts(for combo: KeyCombo, excluding id: ItemID?) -> [HotkeyConflict] {
        var conflicts = hotkeyService.conflicts(for: combo)
        if let launcher = general[HostSettings.launcherHotkey], launcher == combo {
            conflicts.append(HotkeyConflict(owner: HostStrings.launcherHotkeyOwner, canOverride: false))
        }
        for (other, otherCombo) in hotkeys.sorted(by: { $0.key.rawValue < $1.key.rawValue })
        where otherCombo == combo && other != id {
            let title = runtime?.command(other)?.command.title ?? other.rawValue
            conflicts.append(HotkeyConflict(owner: title, canOverride: true))
        }
        return conflicts
    }

    /// Binds every stored hotkey whose item can run now and unbinds the rest. The runtime calls it
    /// after registration, activation and every switch or declaration change.
    func rebindHotkeys() {
        for (id, combo) in hotkeys.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if canBind(id) {
                guard bound[id] != combo else { continue }
                unbind(id)
                do {
                    try bind(id, combo)
                } catch {
                    log.error("hotkey \(combo.description, privacy: .public) could not be bound")
                }
            } else {
                unbind(id)
            }
        }
        for id in bound.keys where hotkeys[id] == nil { unbind(id) }
    }

    /// Unbinds every item hotkey, as at quit.
    func unbindAllHotkeys() {
        for id in Array(bound.keys) { unbind(id) }
    }

    /// The hotkeys bound with the system now, for tests and the self-test.
    public var boundHotkeys: [ItemID: KeyCombo] { bound }

    /// The ID an item's hotkey is registered under with ``HotkeyService``.
    public nonisolated static func bindingID(for id: ItemID) -> String {
        "host.item." + id.rawValue
    }

    private func canBind(_ id: ItemID) -> Bool {
        runtime?.canBindHotkey(for: id) ?? false
    }

    private func bind(_ id: ItemID, _ combo: KeyCombo) throws {
        try hotkeyService.register(combo, id: Self.bindingID(for: id)) { [weak self] in
            self?.runtime?.hotkeyPressed(id)
        }
        bound[id] = combo
    }

    private func unbind(_ id: ItemID) {
        guard bound[id] != nil else { return }
        hotkeyService.unregister(id: Self.bindingID(for: id))
        bound[id] = nil
    }

    // MARK: Favorites

    public func setFavorites(_ ids: [ItemID]) {
        var seen: Set<ItemID> = []
        favorites = ids.filter { seen.insert($0).inserted }
        didChange()
    }

    // MARK: Switches

    public func isEnabled(feature featureID: String) -> Bool {
        if let stored = featureSwitches[featureID] { return stored }
        return runtime?.feature(featureID)?.manifest.isEnabledByDefault ?? false
    }

    /// The manifest default unless the user set a switch. Used at registration, before the entry
    /// exists.
    func isEnabled(feature featureID: String, default defaultValue: Bool) -> Bool {
        featureSwitches[featureID] ?? defaultValue
    }

    public func setEnabled(_ enabled: Bool, feature featureID: String) async {
        featureSwitches[featureID] = enabled
        didChange()
        await runtime?.setFeatureEnabled(enabled, featureID: featureID)
    }

    public func isEnabled(command id: ItemID) -> Bool {
        !disabledCommands.contains(id)
    }

    public func setEnabled(_ enabled: Bool, command id: ItemID) {
        if enabled { disabledCommands.remove(id) } else { disabledCommands.insert(id) }
        didChange()
        runtime?.commandSwitchChanged()
    }

    // MARK: Confirmations

    /// True when the user asked not to be asked this again. `key` is `<feature id>.<suppression key>`.
    public func isConfirmationSuppressed(_ key: String) -> Bool {
        suppressed.contains(key)
    }

    /// Stops asking a confirmation, or asks it again. `key` is `<feature id>.<suppression key>`.
    public func setConfirmationSuppressed(_ suppressedNow: Bool, key: String) {
        if suppressedNow { suppressed.insert(key) } else { suppressed.remove(key) }
        didChange()
    }

    // MARK: Filter dropdowns

    /// The option the user last picked in a dropdown that remembers its selection. `key` names the
    /// page and the dropdown.
    public func filterSelection(_ key: String) -> String? {
        filterSelections[key]
    }

    /// Remembers the option picked in a dropdown that remembers its selection.
    public func setFilterSelection(_ optionID: String, key: String) {
        guard filterSelections[key] != optionID else { return }
        filterSelections[key] = optionID
        didChange()
    }

    // MARK: Missing commands

    /// Notes which commands with an alias or a hotkey are missing, and drops what a command kept
    /// once it has been missing for ``missingCommandGrace``.
    func reconcileCommands(declared: Set<ItemID>) {
        let now = clock.now
        let attached = Set(aliases.keys).union(hotkeys.keys).filter {
            $0.namespace == ItemID.ReservedNamespace.command
        }
        var changed = false
        for id in attached {
            if declared.contains(id) {
                if missingSince.removeValue(forKey: id) != nil { changed = true }
            } else if let since = missingSince[id] {
                guard now.timeIntervalSince(since) >= Self.missingCommandGrace else { continue }
                aliases[id] = nil
                hotkeys[id] = nil
                unbind(id)
                missingSince[id] = nil
                changed = true
            } else {
                missingSince[id] = now
                changed = true
            }
        }
        for id in missingSince.keys where !attached.contains(id) {
            missingSince[id] = nil
            changed = true
        }
        if changed { didChange() }
    }

    /// When each missing command with an alias or a hotkey was first found missing.
    public var missingCommands: [ItemID: Date] { missingSince }

    // MARK: Fallbacks

    /// Replaces the fallback choices, stores them and sends ``changes``. The same choices again do
    /// nothing.
    public func setFallbackChoices(_ choices: FallbackChoices) {
        guard choices != fallbackChoices else { return }
        fallbackChoices = choices
        didChange()
    }

    // MARK: Storage

    private func didChange() {
        changes.send()
        pending = snapshot()
        guard writer == nil else { return }
        writer = Task { await drainWrites() }
    }

    private func drainWrites() async {
        while let next = pending {
            pending = nil
            do {
                try await store.save(next)
            } catch {
                log.error("preferences could not be saved: \(error.localizedDescription, privacy: .public)")
            }
        }
        writer = nil
    }

    private func snapshot() -> PreferencesFile {
        var file = PreferencesFile()
        file.aliases = Dictionary(uniqueKeysWithValues: aliases.map { ($0.key.rawValue, $0.value) })
        file.hotkeys = Dictionary(uniqueKeysWithValues: hotkeys.map { ($0.key.rawValue, $0.value) })
        file.favorites = favorites.map(\.rawValue)
        file.features = featureSwitches
        file.disabledCommands = disabledCommands.map(\.rawValue).sorted()
        file.missingSince = Dictionary(uniqueKeysWithValues: missingSince.map { ($0.key.rawValue, $0.value) })
        file.suppressedConfirmations = suppressed.sorted()
        file.filterSelections = filterSelections
        file.fallbackChoices = fallbackChoices.isEmpty ? nil : fallbackChoices
        return file
    }

    private func apply(_ file: PreferencesFile) {
        func ids<Value>(_ values: [String: Value]) -> [ItemID: Value] {
            var result: [ItemID: Value] = [:]
            for (raw, value) in values {
                if let id = ItemID(rawValue: raw) { result[id] = value }
            }
            return result
        }
        aliases = ids(file.aliases)
        hotkeys = ids(file.hotkeys)
        favorites = file.favorites.compactMap(ItemID.init(rawValue:))
        featureSwitches = file.features
        disabledCommands = Set(file.disabledCommands.compactMap(ItemID.init(rawValue:)))
        missingSince = ids(file.missingSince)
        suppressed = Set(file.suppressedConfirmations)
        filterSelections = file.filterSelections
        fallbackChoices = file.fallbackChoices ?? FallbackChoices()
    }
}
