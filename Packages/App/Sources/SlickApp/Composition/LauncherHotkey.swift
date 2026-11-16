import Foundation
import Kit
import KitHosting
import SettingsUI
import os

/// Binds the launcher hotkey from ``HostSettings/launcherHotkey`` and binds it again whenever the
/// setting changes.
///
/// Two kinds of refusal behave differently:
///
/// - An enabled macOS shortcut holds the combination, as Spotlight holds Command-Space on a new
///   Mac. The hotkey waits: nothing is bound for the launcher, no failure HUD shows, and ``wait``
///   names the holder. While it waits, a timer on Kit's clock checks the system's shortcuts every
///   ``quickInterval`` for ``quickPeriod``, then every ``slowInterval``, and settings windows ask
///   for a check when they open. The moment the combination is free it is bound and
///   ``onBoundAfterWait`` runs. No timer runs while the hotkey is bound.
/// - Another binding or the system refuses it otherwise. The last working combination stays bound,
///   ``onRefusal`` runs, and the refusal is retried after the next change to the item hotkeys,
///   because settings clears an item's hotkey right after it gives the combination to the launcher.
///
/// When the macOS shortcut is one of Spotlight's own, the wait says it can be turned off, and
/// ``turnOffSystemShortcut()`` turns it off through the hotkey service and binds the hotkey. Only
/// the person's Continue on onboarding's hotkey step, the General pane's button and the menu bar
/// menu's item call it, never the launcher by itself. A try that leaves the keys taken changes
/// nothing else and marks the wait ``LauncherHotkeyWait/turnOffFailed``. A shortcut turned off this
/// way is noted, with the time, under ``turnedOffNote``, so the General pane can offer to turn it
/// back on once the launcher uses other keys.
@MainActor final class LauncherHotkey: LauncherHotkeyStatus {
    /// The ID the hotkey is registered under with ``HotkeyService``.
    static let bindingID = "app.launcher"
    /// How often a waiting hotkey checks at first, while the user is likely in System Settings.
    static let quickInterval: Duration = .seconds(2)
    /// How long the quick checks go on, in seconds from the start of the wait.
    static let quickPeriod: TimeInterval = 10 * 60
    /// How often a waiting hotkey checks after that.
    static let slowInterval: Duration = .seconds(30)

    private let hotkeys: any HotkeyService
    private let general: FeatureSettings
    private let retrySignal: ChangeSignal?
    private let clock: any ClockService
    private let press: @MainActor @Sendable () -> Void
    private var watchers: [Task<Void, Never>] = []
    private var recheck: Task<Void, Never>?
    private let log = KitLog.logger(category: "app.hotkey")

    /// The combination bound now, or nil.
    private(set) var bound: KeyCombo?
    /// The combination the setting asks for that could not be bound, with the reason. Nil while the
    /// hotkey waits behind a macOS shortcut.
    private(set) var refusal: (combo: KeyCombo, error: any Error)?
    /// The combination the setting asks for while a macOS shortcut holds it, or nil.
    private(set) var wait: LauncherHotkeyWait?
    /// Sent when ``bound`` or ``wait`` changes.
    let statusChanges = ChangeSignal()
    /// Called after a refusal, for a HUD in the live app. Never called for a wait.
    var onRefusal: ((KeyCombo, any Error) -> Void)?
    /// Called when a combination that waited behind a macOS shortcut is bound, for a HUD.
    var onBoundAfterWait: ((KeyCombo) -> Void)?
    /// The combination whose shortcut the app tried to turn off and could not, while it still waits.
    private var failedTurnOff: KeyCombo?

    /// What the app keeps about a Spotlight shortcut it turned off: which one, its keys and when.
    nonisolated struct TurnedOffNote: CodableSettingValue, Hashable {
        var number: Int
        var owner: String
        var keys: String
        var date: Date
    }

    /// The note in the general settings. Nil until the app turns a shortcut off.
    static let turnedOffNote = SettingKey("turnedOffSystemShortcut", default: TurnedOffNote?.none)

    /// True while the timer that checks a waiting hotkey runs.
    var isRechecking: Bool { recheck != nil }

    /// - Parameters:
    ///   - hotkeys: The hotkey service.
    ///   - settings: The settings service that holds ``HostSettings``.
    ///   - retrySignal: Fires when item hotkeys change, so a refused combination is tried again.
    ///   - clock: Times the checks while the hotkey waits.
    ///   - press: Runs on the main actor when the user presses the hotkey.
    init(
        hotkeys: any HotkeyService, settings: any SettingsService, retrySignal: ChangeSignal?,
        clock: any ClockService = SystemClock(), press: @escaping @MainActor @Sendable () -> Void
    ) {
        self.hotkeys = hotkeys
        general = HostSettings.settings(settings)
        self.retrySignal = retrySignal
        self.clock = clock
        self.press = press
    }

    isolated deinit {
        for watcher in watchers { watcher.cancel() }
        recheck?.cancel()
    }

    /// Binds the hotkey now and follows the setting from here on.
    func start() {
        guard watchers.isEmpty else { return }
        apply()
        let changes = general.changes(of: HostSettings.launcherHotkey)
        watchers.append(
            Task { [weak self] in
                for await _ in changes { self?.apply() }
            })
        if let retrySignal {
            let retries = retrySignal.stream()
            watchers.append(
                Task { [weak self] in
                    for await _ in retries where self?.refusal != nil { self?.apply() }
                })
        }
    }

    /// Stops following the setting and the system's shortcuts and unbinds the hotkey, as at quit.
    func stop() {
        for watcher in watchers { watcher.cancel() }
        watchers = []
        stopRechecking()
        hotkeys.unregister(id: Self.bindingID)
        bound = nil
    }

    /// Does what pressing the bound hotkey does, for scenarios, where the hotkey system is inert.
    /// Returns false when no hotkey is bound.
    @discardableResult
    func simulatePress() -> Bool {
        guard bound != nil else { return false }
        press()
        return true
    }

    /// Checks the system's shortcuts again while the hotkey waits, and binds it if the combination
    /// is free. Does nothing otherwise, so it costs nothing while the hotkey is bound.
    func checkNow() {
        guard wait != nil else { return }
        apply()
    }

    // MARK: Turning a macOS shortcut off

    /// Turns off the macOS shortcut the hotkey waits for and binds the hotkey, when the wait says
    /// the app can. True when the hotkey is bound afterwards. A try that leaves the keys taken
    /// changes nothing else and marks the wait as failed, so every place offers the advice instead.
    func turnOffSystemShortcut() async -> Bool {
        guard let wait, wait.canTurnOff else { return false }
        let combo = wait.combo
        guard let shortcut = await hotkeys.turnOffSystemShortcut(for: combo) else {
            log.error("could not turn off the macOS shortcut on \(combo.description, privacy: .public)")
            if self.wait?.combo == combo {
                failedTurnOff = combo
                settle(bound: nil, wait: LauncherHotkeyWait(combo: combo, owner: wait.owner, turnOffFailed: true))
            }
            return false
        }
        log.info("turned off \(shortcut.owner, privacy: .public)'s shortcut \(shortcut.number) for the launcher")
        general[Self.turnedOffNote] = TurnedOffNote(
            number: shortcut.number, owner: shortcut.owner, keys: combo.description, date: clock.now)
        apply()
        return bound == combo
    }

    /// The Spotlight shortcut the app turned off, while the launcher hotkey uses other keys and the
    /// shortcut is still off. Reads the system's shortcuts, so it is not for a hot path.
    var turnedOffShortcut: TurnedOffShortcut? {
        guard let note = general[Self.turnedOffNote], let combo = KeyCombo(parsing: note.keys),
            general[HostSettings.launcherHotkey] != combo,
            !hotkeys.conflicts(for: combo).contains(where: \.isSystemShortcut)
        else { return nil }
        return TurnedOffShortcut(combo: combo, owner: note.owner, date: note.date)
    }

    /// Turns the noted shortcut back on, as it was turned off, and forgets the note. True when the
    /// system took it.
    func turnShortcutBackOn() async -> Bool {
        guard let note = general[Self.turnedOffNote] else { return false }
        guard await hotkeys.turnOnSystemShortcut(SystemShortcut(number: note.number, owner: note.owner)) else {
            log.error("could not turn \(note.owner, privacy: .public)'s shortcut \(note.number) back on")
            return false
        }
        general[Self.turnedOffNote] = nil
        statusChanges.send()
        return true
    }

    /// Makes the binding match the setting.
    func apply() {
        let wanted = general[HostSettings.launcherHotkey]
        guard wanted != bound || refusal != nil || wait != nil else { return }
        guard let wanted else {
            hotkeys.unregister(id: Self.bindingID)
            settle(bound: nil, wait: nil)
            refusal = nil
            return
        }
        if let holder = hotkeys.conflicts(for: wanted).first(where: \.isSystemShortcut) {
            waitBehind(holder, for: wanted)
            return
        }
        let press = press
        let waited = wait?.combo == wanted
        do {
            try hotkeys.register(wanted, id: Self.bindingID) { press() }
            refusal = nil
            settle(bound: wanted, wait: nil)
            if waited {
                log.info("launcher hotkey \(wanted.description, privacy: .public) is free and bound")
                onBoundAfterWait?(wanted)
            }
        } catch HotkeyError.conflict(let conflicts) where conflicts.contains(where: \.isSystemShortcut) {
            // A macOS shortcut took the combination between the check and the registration.
            if let holder = conflicts.first(where: \.isSystemShortcut) { waitBehind(holder, for: wanted) }
        } catch {
            // The service keeps the previous registration under the same ID when a replacement
            // fails, so `bound` still holds.
            refusal = (wanted, error)
            settle(bound: bound, wait: nil)
            log.error("launcher hotkey \(wanted.description, privacy: .public) refused: \(String(describing: error))")
            onRefusal?(wanted, error)
        }
    }

    // MARK: Waiting

    /// Unbinds the launcher and waits until `holder` lets go of `combo`.
    private func waitBehind(_ holder: HotkeyConflict, for combo: KeyCombo) {
        if bound != nil { hotkeys.unregister(id: Self.bindingID) }
        refusal = nil
        let isNew = wait?.combo != combo
        if isNew {
            log.info(
                "launcher hotkey \(combo.description, privacy: .public) waits for \(holder.owner, privacy: .public)")
        }
        let failed = failedTurnOff == combo
        settle(
            bound: nil,
            wait: LauncherHotkeyWait(
                combo: combo, owner: holder.owner, canTurnOff: holder.canTurnOff && !failed, turnOffFailed: failed))
        if isNew || recheck == nil { startRechecking() }
    }

    /// Sets the state, sends one change when it changed, and stops the timer once nothing waits.
    private func settle(bound newBound: KeyCombo?, wait newWait: LauncherHotkeyWait?) {
        let changed = newBound != bound || newWait != wait
        bound = newBound
        wait = newWait
        if newWait?.combo != failedTurnOff { failedTurnOff = nil }
        if newWait == nil { stopRechecking() }
        if changed { statusChanges.send() }
    }

    private func startRechecking() {
        recheck?.cancel()
        let clock = clock
        let started = clock.now
        recheck = Task { [weak self] in
            while !Task.isCancelled {
                let waited = clock.now.timeIntervalSince(started)
                let interval = waited < Self.quickPeriod ? Self.quickInterval : Self.slowInterval
                do {
                    try await clock.sleep(for: interval)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.checkNow()
            }
        }
    }

    private func stopRechecking() {
        recheck?.cancel()
        recheck = nil
    }
}
