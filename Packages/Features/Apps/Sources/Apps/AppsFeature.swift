import Foundation
import Kit
import os

/// Applications: every installed app and every System Settings pane in root search, actions to
/// open, reveal, quit, hide and restart apps, and the Quit All Applications and Running Applications
/// commands.
///
/// This is the reference feature. It shows the parts most features need:
/// - Two catalog sources in stored properties, each with its own namespace (`Sources.swift`).
/// - Rows built off the main thread from plain values, with a payload that rebuilds their actions
///   after a relaunch (`AppRows.swift`, `AppActions.swift`).
/// - Two services of its own behind `FeatureServiceKey`s, a live one and an isolated one each, so
///   the feature never branches on the run environment (`AppLibrary.swift`, `RunningApps.swift`).
/// - Background work in `activate()`: a file watch, a settings watch and a running-app watch, each
///   a task that sends one change signal.
/// - A command with a confirmation, a list page and a settings pane.
public final class AppsFeature: Feature {
    public static let manifest = FeatureManifest(
        id: "apps", name: "Applications", icon: .symbol("square.grid.2x2"),
        summary: "Open and manage your applications, and go straight to any System Settings pane.")

    let context: FeatureContext
    let library: any AppLibrary
    let runningApps: any RunningAppsService
    /// Sent when the installed or running apps change. The app catalog and the Running Applications
    /// page reload on it.
    let changes = ChangeSignal()
    /// The last scan, in root order.
    private(set) var installed: [InstalledApp] = []
    /// The running apps, as of the last change the service reported.
    private(set) var running: [RunningApp] = []

    private var roots: [AppScanRoot] = []
    /// The latest scan and running-app refresh. Each new one waits for the one before, so results
    /// apply in order.
    private var scan: Task<Void, Never>?
    private var runningRefresh: Task<Void, Never>?
    private var panes: Task<[SystemSettingsPane], Never>?
    private var watching: Task<Void, Never>?
    private var listening: [Task<Void, Never>] = []

    private lazy var appCatalog = AppCatalog(feature: self)
    private lazy var paneCatalog = SettingsPaneCatalog(feature: self)
    private lazy var runningList = RunningAppsList(feature: self)

    /// Does no I/O. The services touch nothing until ``activate()`` starts the first scan.
    public init(context: FeatureContext) {
        self.context = context
        library = context.service(AppLibraryKey.self)
        runningApps = context.service(RunningAppsKey.self)
    }

    /// Starts the watches and the first scan, and returns without waiting for it. Root's first read
    /// of the catalog waits for the scan instead.
    public func activate() async {
        // Subscribe before starting the tasks that read, so no change in between is lost.
        let runningChanges = runningApps.changes()
        let folderChanges = context.settings.changes(of: AppsSettings.extraFolders)
        refreshRunning()
        listening = [
            Task { [weak self] in
                for await _ in runningChanges { await self?.refreshRunning().value }
            },
            Task { [weak self] in
                for await _ in folderChanges { await self?.watchFolders().value }
            },
        ]
        watchFolders()
    }

    public func deactivate() async {
        for task in listening { task.cancel() }
        listening = []
        watching?.cancel()
        watching = nil
    }

    public var catalogSources: [any CatalogSource] { [appCatalog, paneCatalog] }

    public var commands: [Command] {
        [
            Command(
                id: "running", title: "Running Applications", icon: .symbol("macwindow.on.rectangle"),
                keywords: ["quit", "open apps", "processes"]
            ) { _ in
                .push(
                    .list(
                        ListPage(
                            self.runningList, searchPlaceholder: "Search running applications",
                            emptyState: EmptyState(icon: .symbol("moon.zzz"), title: "No Running Applications"))))
            },
            Command(
                id: "quit-all", title: "Quit All Applications", icon: .symbol("xmark.circle"),
                keywords: ["close all"],
                confirmation: Confirmation(
                    "Quit All Applications?",
                    message: "Apps you keep running in settings stay open. An app with unsaved changes may ask first.",
                    confirmTitle: "Quit All", isDestructive: true, suppressionKey: "quit-all")
            ) { _ in
                await self.quitAll()
            },
        ]
    }

    public var settingsPane: SettingsPane? {
        SettingsPane([
            SettingsSection(
                "Search",
                items: [
                    .list(
                        "Extra folders", key: AppsSettings.extraFolders, itemKind: .folder,
                        info: "Apps in these folders and their subfolders show in search."),
                    .list(
                        "Hidden applications", key: AppsSettings.hiddenApps, itemKind: .application,
                        info: "These apps never show in search."),
                    .toggle(
                        "Show System Settings panes", key: AppsSettings.showsSettingsPanes,
                        info: "Find each pane of System Settings, and the sections inside it, by name."),
                    .button(
                        "Rescan Applications",
                        info: "The list updates by itself when an app folder changes."
                    ) { context in
                        await self.rescan().value
                        context.showToast(.success("Found \(self.installed.count) Applications"))
                    },
                ]),
            SettingsSection(
                "Quit All Applications",
                items: [
                    .list(
                        "Keep running", key: AppsSettings.keepRunning, itemKind: .application,
                        info: "Quit All Applications leaves these apps open.")
                ]),
        ])
    }

    // MARK: - What the sources read

    /// Returns once the scan and the running-app read that activation started, and any that
    /// replaced them, have applied. Root search reads the catalog after the scan anyway, but the
    /// rows and the Running Applications page also show which apps run, so scenarios and the
    /// self-test wait for both before they type.
    public func waitUntilReady() async {
        while let current = scan {
            await current.value
            if scan == current { break }
        }
        while let current = runningRefresh {
            await current.value
            if runningRefresh == current { break }
        }
    }

    /// Every installed app's row, after the scan in progress, if any, has finished.
    func appRows() async -> [Row] {
        await scan?.value
        await runningRefresh?.value
        let hidden = Set(context.settings[AppsSettings.hiddenApps])
        return await AppRows.catalog(installed, running: running, hidden: hidden)
    }

    /// The installed apps, after the scan in progress, if any, has finished.
    func installedAfterScan() async -> [InstalledApp] {
        await scan?.value
        return installed
    }

    /// The Settings panes, scanned once per launch on first use. Panes change only with the system,
    /// and the system restarts the app when it updates.
    func settingsPanes() async -> [SystemSettingsPane] {
        if panes == nil {
            let library = library
            panes = Task { await library.settingsPanes() }
        }
        return await panes?.value ?? []
    }

    // MARK: - Keeping current

    /// Scans every folder again and sends ``changes`` when the result differs. Scans run one after
    /// another; the returned task ends when this one has applied.
    @discardableResult
    func rescan() -> Task<Void, Never> {
        let previous = scan
        let roots = roots
        let library = library
        let task = Task {
            await previous?.value
            let found = await library.applications(in: roots)
            // The folders changed while this scan ran; the scan for the new folders applies instead.
            guard roots == self.roots else { return }
            if found != installed {
                installed = found
                context.log.info("Found \(found.count) applications")
                changes.send()
            }
        }
        scan = task
        return task
    }

    /// Reads the running apps again and sends ``changes`` when they differ.
    @discardableResult
    func refreshRunning() -> Task<Void, Never> {
        let previous = runningRefresh
        let service = runningApps
        let task = Task {
            await previous?.value
            let now = await service.apps()
            if now != running {
                running = now
                changes.send()
            }
        }
        runningRefresh = task
        return task
    }

    /// Watches the app folders, replacing any earlier watch, and scans them. System folders change
    /// only with the system, so they are not watched.
    @discardableResult
    private func watchFolders() -> Task<Void, Never> {
        watching?.cancel()
        let extra = context.settings[AppsSettings.extraFolders].map { URL(filePath: $0, directoryHint: .isDirectory) }
        roots = library.roots(adding: extra)
        let events = context.fileWatcher.watch(roots.filter { !$0.isSystem }.map(\.folder))
        watching = Task { [weak self] in
            for await _ in events { await self?.rescan().value }
        }
        return rescan()
    }

    /// Asks every running app to quit, except this app and those the user keeps running.
    private func quitAll() async -> ActionOutcome {
        let keep = Set(context.settings[AppsSettings.keepRunning]).union([Brand.bundleID])
        let targets = await runningApps.apps().filter { app in !(app.bundleID.map(keep.contains) ?? false) }
        guard !targets.isEmpty else { return .close(hud: "No Applications to Quit") }
        var refused: [String] = []
        for app in targets {
            if await !runningApps.quit(app) { refused.append(app.name) }
        }
        if !refused.isEmpty {
            return .close(hud: .failure("Could Not Quit " + refused.joined(separator: ", ")))
        }
        return .close(
            hud: HUD(targets.count == 1 ? "Quitting 1 Application" : "Quitting \(targets.count) Applications"))
    }
}
