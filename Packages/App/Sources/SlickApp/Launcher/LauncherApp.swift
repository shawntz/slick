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
@MainActor final class LauncherApp: NSObject, NSApplicationDelegate {
    private let folders: RunFolders
    private var assembly: Assembly?
    private var statusItem: StatusItemController?
    private var onboarding: OnboardingController?
    private var summonObserver: (any NSObjectProtocol)?
    private var statusWatcher: Task<Void, Never>?
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
        app.run()
        exit(0)
    }

    // MARK: Starting

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SingleInstance.anotherCopyRuns() {
            SlickMain.printError(AppStrings.alreadyRunning)
            SingleInstance.askRunningCopyToSummon()
            exit(0)
        }
        do {
            try folders.create()
        } catch {
            SlickMain.printError("\(Brand.name): cannot make the data folder: \(error.localizedDescription)")
        }
        let assembly = Assembly(
            .init(
                environment: .live, dataRoot: folders.dataRoot, firstRunSeeds: { await FirstRunSeeds.gather() },
                showsWindows: true))
        self.assembly = assembly
        assembly.hotkey.onRefusal = { [weak assembly] combo, _ in
            assembly?.panel?.showHUD(.failure(AppStrings.hotkeyRefused(combo.description)))
        }
        let status = StatusItemController(
            settings: assembly.services.settings,
            openLauncher: { [weak assembly] in assembly?.panel?.summon() },
            openSettings: { [weak assembly] in assembly?.settings.open() })
        statusItem = status
        summonObserver = SingleInstance.listen { [weak assembly] in assembly?.panel?.summon() }

        Task {
            await assembly.start(prewarm: true)
            status.start()
            watchRootStatus(assembly)
            isReady = true
            for url in pendingLinks { assembly.links.handle(url) }
            pendingLinks = []
            showOnboardingIfNeeded(assembly)
        }
    }

    /// Onboarding shows on the first launch only, and only here in the live launcher.
    private func showOnboardingIfNeeded(_ assembly: Assembly) {
        guard OnboardingController.isNeeded(assembly.services.settings) else { return }
        let onboarding = OnboardingController(dependencies: assembly.dependencies) { [weak self] in
            self?.onboarding = nil
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
        statusItem?.stop()
        if let summonObserver { DistributedNotificationCenter.default().removeObserver(summonObserver) }
        Task {
            await assembly.shutdown()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
