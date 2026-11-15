import AppKit
import Foundation
import Host
import Kit
import KitHosting
import Root
import SettingsUI
import os

/// The launcher a person uses: an accessory app with no Dock icon, one copy at a time, the panel on
/// the launcher hotkey, a menu bar item, deep links, settings, onboarding on the first launch, and
/// a clean quit that writes everything learned.
///
/// Agents and tests never start this mode. They use `--selftest`, `--bench` and `--scenario`.
///
/// Its launch path has never run on a person's Mac: see the first-run report.
@MainActor final class LauncherApp: NSObject, NSApplicationDelegate {
    /// How long quitting waits for the launcher to write what it learned before it quits anyway.
    static let shutdownLimit: Duration = .seconds(5)

    private let folders: RunFolders
    private var assembly: Assembly?
    private var statusItem: StatusItemController?
    private var onboarding: OnboardingController?
    private var summonObserver: (any NSObjectProtocol)?
    private var statusWatcher: Task<Void, Never>?
    private var hotkeyWatcher: Task<Void, Never>?
    /// The lock that marks this process as the live launcher on its data folder, held until exit.
    private var instanceLock: InstanceLock?
    /// Links that arrived before the launcher was ready.
    private var pendingLinks: [URL] = []
    private var isReady = false
    private var isQuitting = false
    private let log = KitLog.logger(category: "app.launcher")

    private init(folders: RunFolders) {
        self.folders = folders
    }

    static func run(folders: RunFolders) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = LauncherApp(folders: folders)
        app.delegate = delegate
        // The application holds its delegate weakly; keep it alive for as long as the app runs.
        withExtendedLifetime(delegate) { app.run() }
        exit(0)
    }

    // MARK: Starting

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try folders.create()
        } catch {
            SlickMain.printError("\(Brand.name): cannot make the data folder: \(error.localizedDescription)")
        }
        switch SingleInstance.lock(dataRoot: folders.dataRoot) {
        case .acquired(let lock):
            instanceLock = lock
        case .heldElsewhere:
            SlickMain.printError(AppStrings.alreadyRunning)
            SingleInstance.askRunningCopyToSummon()
            exit(0)
        case .unavailable(let code):
            // Better to run twice than not at all; the engine still refuses a second writer.
            log.error("the launcher lock could not be taken: errno \(code)")
        }
        let assembly = Assembly(
            .init(
                environment: .live, dataRoot: folders.dataRoot, firstRunSeeds: { await FirstRunSeeds.gather() },
                showsWindows: true))
        self.assembly = assembly
        assembly.hotkey.onRefusal = { [weak assembly] combo, _ in
            assembly?.panel?.showHUD(.failure(AppStrings.hotkeyRefused(combo.displayString)))
        }
        let workspace = assembly.services.workspace
        let status = StatusItemController(
            settings: assembly.services.settings,
            openLauncher: { [weak assembly] in assembly?.panel?.summon() },
            openSettings: { [weak assembly] in assembly?.settings.open() },
            openKeyboardSettings: { Task { try? await workspace.open(SpotlightShortcutGuide.keyboardSettingsURL) } })
        statusItem = status
        // The menu bar item comes first: while the hotkey waits behind Spotlight, it is the only
        // way to open the launcher.
        status.start()
        watchHotkey(assembly, status: status)
        summonObserver = SingleInstance.listen { [weak assembly] in assembly?.panel?.summon() }
        // Onboarding opens at once, while macOS still lets a just-launched app come forward. Its
        // steps read the features as they register.
        showOnboardingIfNeeded(assembly)

        Task {
            await assembly.start(prewarm: true)
            watchRootStatus(assembly)
            isReady = true
            for url in pendingLinks { assembly.links.handle(url) }
            pendingLinks = []
        }
    }

    /// Keeps the menu bar item's hotkey notice in step with the launcher hotkey.
    private func watchHotkey(_ assembly: Assembly, status: StatusItemController) {
        let hotkey = assembly.hotkey
        let changes = hotkey.statusChanges.stream()
        status.hotkeyWait = hotkey.wait
        hotkeyWatcher = Task { [weak hotkey, weak status] in
            for await _ in changes {
                guard let hotkey, let status else { return }
                status.hotkeyWait = hotkey.wait
            }
        }
    }

    /// Onboarding shows on the first launch only, and only here in the live launcher.
    private func showOnboardingIfNeeded(_ assembly: Assembly) {
        guard OnboardingController.isNeeded(assembly.services.settings) else { return }
        let onboarding = OnboardingController(dependencies: assembly.dependencies) { [weak self] in
            // Let go of the window after the Start button's action has returned, not inside it.
            Task { [weak self] in self?.onboarding = nil }
        }
        self.onboarding = onboarding
        onboarding.show()
    }

    /// Says clearly when root search could not use the data folder: in the menu bar item, as a
    /// HUD and on standard error.
    private func watchRootStatus(_ assembly: Assembly) {
        let root = assembly.root
        let changes = root.statusChanges.stream()
        report(root.status, assembly: assembly)
        statusWatcher = Task { [weak self, weak assembly] in
            for await _ in changes {
                guard let self, let assembly else { return }
                self.report(assembly.root.status, assembly: assembly)
            }
        }
    }

    private func report(_ status: RootStatus, assembly: Assembly) {
        let message: String?
        switch status {
        case .inMemory(.directoryInUse): message = AppStrings.dataFolderInUse
        case .inMemory(.directoryUnusable): message = AppStrings.dataFolderUnusable
        case .failed(let reason): message = reason
        case .opening, .ready: message = nil
        }
        statusItem?.problem = message
        guard let message else { return }
        SlickMain.printError("\(Brand.name): \(message)")
        log.error("\(message, privacy: .public)")
        assembly.panel?.showHUD(.failure(message))
    }

    // MARK: Deep links and reopening

    func application(_ application: NSApplication, open urls: [URL]) {
        guard isReady, let assembly else {
            pendingLinks += urls
            return
        }
        for url in urls { assembly.links.handle(url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        assembly?.panel?.summon()
        return false
    }

    // MARK: Quitting

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let assembly, !isQuitting else { return .terminateNow }
        isQuitting = true
        statusWatcher?.cancel()
        hotkeyWatcher?.cancel()
        statusItem?.stop()
        if let summonObserver { DistributedNotificationCenter.default().removeObserver(summonObserver) }
        // Reply once: when the shutdown is done, or after the limit if it hangs.
        let reply = TerminateReply()
        Task {
            await assembly.shutdown()
            reply.send()
        }
        Task {
            try? await Task.sleep(for: Self.shutdownLimit)
            if reply.send() { log.error("quit without a full shutdown after \(Self.shutdownLimit)") }
        }
        return .terminateLater
    }
}

/// Answers the application's termination question once, from whichever path gets there first.
@MainActor private final class TerminateReply {
    private var sent = false

    /// Replies unless a reply went out already. Returns true when this call replied.
    @discardableResult
    func send() -> Bool {
        guard !sent else { return false }
        sent = true
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
        return true
    }
}
