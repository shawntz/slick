import Kit
import KitHosting
import os

/// Binds the launcher hotkey from ``HostSettings/launcherHotkey`` and binds it again whenever the
/// setting changes. When the system or another binding refuses a combination, the last working one
/// stays bound and the refusal is retried after the next change to the item hotkeys, because
/// settings clears an item's hotkey right after it gives the combination to the launcher.
@MainActor final class LauncherHotkey {
    /// The ID the hotkey is registered under with ``HotkeyService``.
    static let bindingID = "app.launcher"

    private let hotkeys: any HotkeyService
    private let general: FeatureSettings
    private let retrySignal: ChangeSignal?
    private let press: @MainActor @Sendable () -> Void
    private var watchers: [Task<Void, Never>] = []
    private let log = KitLog.logger(category: "app.hotkey")

    /// The combination bound now, or nil.
    private(set) var bound: KeyCombo?
    /// The combination the setting asks for that could not be bound, with the reason.
    private(set) var refusal: (combo: KeyCombo, error: any Error)?
    /// Called after a refusal, for a HUD in the live app.
    var onRefusal: ((KeyCombo, any Error) -> Void)?

    /// - Parameters:
    ///   - hotkeys: The hotkey service.
    ///   - settings: The settings service that holds ``HostSettings``.
    ///   - retrySignal: Fires when item hotkeys change, so a refused combination is tried again.
    ///   - press: Runs on the main actor when the user presses the hotkey.
    init(
        hotkeys: any HotkeyService, settings: any SettingsService, retrySignal: ChangeSignal?,
        press: @escaping @MainActor @Sendable () -> Void
    ) {
        self.hotkeys = hotkeys
        general = HostSettings.settings(settings)
        self.retrySignal = retrySignal
        self.press = press
    }

    isolated deinit {
        for watcher in watchers { watcher.cancel() }
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

    /// Stops following the setting and unbinds the hotkey, as at quit.
    func stop() {
        for watcher in watchers { watcher.cancel() }
        watchers = []
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

    /// Makes the binding match the setting.
    func apply() {
        let wanted = general[HostSettings.launcherHotkey]
        guard wanted != bound || refusal != nil else { return }
        guard let wanted else {
            hotkeys.unregister(id: Self.bindingID)
            bound = nil
            refusal = nil
            return
        }
        let press = press
        do {
            try hotkeys.register(wanted, id: Self.bindingID) { press() }
            bound = wanted
            refusal = nil
        } catch {
            // The service keeps the previous registration under the same ID when a replacement
            // fails, so `bound` still holds.
            refusal = (wanted, error)
            log.error("launcher hotkey \(wanted.description, privacy: .public) refused: \(String(describing: error))")
            onRefusal?(wanted, error)
        }
    }
}
