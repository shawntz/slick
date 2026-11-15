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
        settle(bound: nil, wait: LauncherHotkeyWait(combo: combo, owner: holder.owner))
        if isNew || recheck == nil { startRechecking() }
    }

    /// Sets the state, sends one change when it changed, and stops the timer once nothing waits.
    private func settle(bound newBound: KeyCombo?, wait newWait: LauncherHotkeyWait?) {
        let changed = newBound != bound || newWait != wait
        bound = newBound
        wait = newWait
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
