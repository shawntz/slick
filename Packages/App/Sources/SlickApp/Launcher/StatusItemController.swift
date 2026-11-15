import AppKit
import Kit
import KitHosting

/// The menu bar item: a bolt that opens a small menu with Open, Settings and Quit. It follows
/// ``HostSettings/showStatusItem``. When root search keeps learning in memory, the menu says why.
@MainActor final class StatusItemController: NSObject {
    private let general: FeatureSettings
    private let openLauncher: () -> Void
    private let openSettings: () -> Void
    private var item: NSStatusItem?
    private var watcher: Task<Void, Never>?

    /// A problem to name at the top of the menu, such as the data folder being in use.
    var problem: String? {
        didSet { item?.menu = makeMenu() }
    }

    /// True while the item is in the menu bar.
    var isInstalled: Bool { item != nil }

    init(settings: any SettingsService, openLauncher: @escaping () -> Void, openSettings: @escaping () -> Void) {
        general = HostSettings.settings(settings)
        self.openLauncher = openLauncher
        self.openSettings = openSettings
    }

    isolated deinit {
        watcher?.cancel()
    }

    /// Shows the item when the setting says so, and follows the setting from now on.
    func start() {
        apply()
        let changes = general.changes(of: HostSettings.showStatusItem)
        watcher = Task { [weak self] in
            for await _ in changes { self?.apply() }
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        remove()
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

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        if let problem {
            let line = NSMenuItem(title: problem, action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
            menu.addItem(.separator())
        }
        let open = NSMenuItem(title: AppStrings.openLauncher, action: #selector(openFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let settings = NSMenuItem(title: AppStrings.settings, action: #selector(settingsFromMenu), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
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
}
