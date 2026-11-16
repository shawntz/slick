import AppKit
import Kit
import KitHosting
import SettingsUI

/// The menu bar item: a bolt that opens a small menu with Open, Settings, Check for Updates and
/// Quit. It follows ``HostSettings/showStatusItem``. When root search keeps learning in memory, the
/// menu says why. While a macOS shortcut uses the launcher hotkey's keys, the menu names it and
/// offers to turn it off, for Spotlight's own shortcuts, or to open Keyboard settings.
///
/// Check for Updates shows only in a build that updates itself. When a scheduled check found an
/// update, the menu leads with an item that names it and opens the updater's window, until the
/// person looks at it. While the item is hidden, the updater shows such an update in its own window,
/// because no menu can offer it.
@MainActor final class StatusItemController: NSObject, NSMenuItemValidation {
    private let general: FeatureSettings
    private let updates: any UpdateControl
    private let openLauncher: () -> Void
    private let openSettings: () -> Void
    private let openKeyboardSettings: () -> Void
    private let turnOffShortcut: () -> Void
    private var item: NSStatusItem?
    private var watcher: Task<Void, Never>?
    private var updatesWatcher: Task<Void, Never>?
    /// The update the menu last offered, so a change rebuilds it only when that changes.
    private var offeredUpdate: String?

    /// A problem to name at the top of the menu, such as the data folder being in use.
    var problem: String? {
        didSet { item?.menu = makeMenu() }
    }

    /// The launcher hotkey's wait for a macOS shortcut, named at the top of the menu, or nil.
    var hotkeyWait: LauncherHotkeyWait? {
        didSet {
            guard hotkeyWait != oldValue else { return }
            item?.menu = makeMenu()
        }
    }

    /// True while the item is in the menu bar.
    var isInstalled: Bool { item != nil }

    /// Whether the menu can offer an update a scheduled check found: while the item is in the menu
    /// bar, which follows ``HostSettings/showStatusItem``. The updater asks each time it finds one,
    /// so hiding the item later counts too.
    static func remindsUpdates(settings: any SettingsService) -> @MainActor () -> Bool {
        let general = HostSettings.settings(settings)
        return { general[HostSettings.showStatusItem] }
    }

    init(
        settings: any SettingsService, updates: any UpdateControl = NoUpdates(), openLauncher: @escaping () -> Void,
        openSettings: @escaping () -> Void, openKeyboardSettings: @escaping () -> Void = {},
        turnOffShortcut: @escaping () -> Void = {}
    ) {
        general = HostSettings.settings(settings)
        self.updates = updates
        self.openLauncher = openLauncher
        self.openSettings = openSettings
        self.openKeyboardSettings = openKeyboardSettings
        self.turnOffShortcut = turnOffShortcut
    }

    isolated deinit {
        watcher?.cancel()
        updatesWatcher?.cancel()
    }

    /// Shows the item when the setting says so, and follows the setting and the updater from now on.
    func start() {
        apply()
        let changes = general.changes(of: HostSettings.showStatusItem)
        watcher = Task { [weak self] in
            for await _ in changes { self?.apply() }
        }
        let updateChanges = updates.changes.stream()
        updatesWatcher = Task { [weak self] in
            for await _ in updateChanges { self?.updatesChanged() }
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        updatesWatcher?.cancel()
        updatesWatcher = nil
        remove()
    }

    /// Rebuilds the menu when the update it offers comes or goes.
    private func updatesChanged() {
        guard updates.waitingVersion != offeredUpdate else { return }
        item?.menu = makeMenu()
    }

    private func apply() {
        if general[HostSettings.showStatusItem] { install() } else { remove() }
    }

    private func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: Brand.name)
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = Brand.name
        item.menu = makeMenu()
        self.item = item
    }

    private func remove() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    /// The menu as it stands. Making it touches nothing on screen.
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        offeredUpdate = updates.waitingVersion
        if let version = offeredUpdate {
            let update = NSMenuItem(
                title: AppStrings.updateWaiting(version), action: #selector(checkForUpdatesFromMenu), keyEquivalent: "")
            update.target = self
            menu.addItem(update)
            menu.addItem(.separator())
        }
        if let problem {
            let line = NSMenuItem(title: problem, action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
            menu.addItem(.separator())
        }
        if let hotkeyWait {
            let note = SpotlightShortcutGuide.menuToolTip(hotkeyWait)
            let line = NSMenuItem(title: SpotlightShortcutGuide.menuTitle(hotkeyWait), action: nil, keyEquivalent: "")
            line.isEnabled = false
            line.toolTip = note
            menu.addItem(line)
            let fix =
                hotkeyWait.canTurnOff
                ? NSMenuItem(
                    title: SpotlightShortcutGuide.turnOffButton(hotkeyWait), action: #selector(turnOffFromMenu),
                    keyEquivalent: "")
                : NSMenuItem(
                    title: SpotlightShortcutGuide.openButton, action: #selector(keyboardSettingsFromMenu),
                    keyEquivalent: "")
            fix.target = self
            fix.toolTip = note
            menu.addItem(fix)
            menu.addItem(.separator())
        }
        let open = NSMenuItem(title: AppStrings.openLauncher, action: #selector(openFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let settings = NSMenuItem(title: AppStrings.settings, action: #selector(settingsFromMenu), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        if updates.isAvailable {
            let check = NSMenuItem(
                title: AppStrings.checkForUpdates, action: #selector(checkForUpdatesFromMenu), keyEquivalent: "")
            check.target = self
            menu.addItem(check)
            menu.addItem(.separator())
        }
        let quit = NSMenuItem(
            title: AppStrings.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    @objc private func openFromMenu() {
        openLauncher()
    }

    @objc private func settingsFromMenu() {
        openSettings()
    }

    @objc private func keyboardSettingsFromMenu() {
        openKeyboardSettings()
    }

    /// The person's yes to turning off the macOS shortcut that uses the launcher's keys.
    @objc private func turnOffFromMenu() {
        turnOffShortcut()
    }

    /// Opens the updater's window: the update a scheduled check found, or a check the person asked for.
    @objc private func checkForUpdatesFromMenu() {
        updates.checkNow()
    }

    /// The update items work only while the updater can check, as while it downloads in the
    /// background it cannot. Every other item stays as it was made.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(checkForUpdatesFromMenu) else { return menuItem.isEnabled }
        return updates.canCheckNow
    }
}
