import Foundation
import Kit
import os

/// Script commands: every script in the script folders becomes a command.
///
/// - A script declares its title, mode, arguments and more in comments at its top, in the format
///   of the public script command collections. `HeaderParser.swift` reads it.
/// - Folders are scanned off the main thread through the feature's own `ScriptLibrary` service,
///   watched through Kit's file watching service, and scanned again on any change. Commands
///   follow through ``declarationChanges``. Command IDs come from the file's path, so they are
///   the same after a relaunch.
/// - Scripts run through Kit's process service with their interpreter, in five modes
///   with a time limit and an output limit from settings. `ScriptCommands.swift` runs them.
/// - Nothing runs that the user did not start, except inline scripts they turned automatic
///   refresh on for. Scripts in a folder the user added stay off until they turn the folder on.
public final class ScriptsFeature: Feature {
    public static let manifest = FeatureManifest(
        id: "scripts", name: Strings.featureName, icon: .symbol("terminal"), summary: Strings.featureSummary,
        permissions: [PermissionNeed(.accessibility, reason: Strings.pasteReason)])

    let context: FeatureContext
    let library: any ScriptLibrary
    /// The folder in the feature's storage, always on.
    let defaultFolder: URL
    /// Sent when the scripts found change. The commands, the status and Manage Script Commands
    /// follow it.
    let changes = ChangeSignal()
    /// The last scan.
    private(set) var catalog = ScriptCatalog()

    private let subtitles = InlineSubtitles()
    private lazy var factory = ScriptCommands(context: context, subtitles: subtitles)
    private lazy var manageList = ManageScriptsList(feature: self)
    /// The folders as of the last settings read, default first.
    private var folders: [ScriptFolder] = []
    private var setup: Task<Void, Never>?
    /// The latest scan. Each waits for the one before, so results apply in order.
    private var scan: Task<Void, Never>?
    private var watching: Task<Void, Never>?
    private var listening: [Task<Void, Never>] = []

    /// Does no I/O.
    public init(context: FeatureContext) {
        self.context = context
        library = context.service(ScriptLibraryKey.self)
        defaultFolder = Self.defaultFolder(context.storage)
        folders = currentFolders()
    }

    nonisolated static func defaultFolder(_ storage: FeatureStorage) -> URL {
        storage.dataDirectory.appending(path: Strings.defaultFolderFileName, directoryHint: .isDirectory)
    }

    /// Creates the default folder, starts watching the folders and scans them, and returns without
    /// waiting.
    public func activate() async {
        // A second activation without a deactivation in between replaces the first one's work.
        for task in listening { task.cancel() }
        setup?.cancel()
        // Subscribe before starting the tasks that read, so no change in between is lost.
        let settingChanges = context.settings.changes(ofAny: [
            ScriptsSettings.folders.erased, ScriptsSettings.enabledFolders.erased,
            ScriptsSettings.refreshingInline.erased, ScriptsSettings.remoteIcons.erased,
        ])
        listening = [
            Task { [weak self] in
                for await name in settingChanges { await self?.settingChanged(name) }
            }
        ]
        let (library, folder) = (library, defaultFolder)
        setup = Task { [weak self] in
            do {
                try await library.makeFolder(folder)
            } catch {
                self?.context.log.error(
                    "Could not create the script folder: \(error.localizedDescription, privacy: .private)")
            }
            await self?.watchFolders().value
        }
    }

    public func deactivate() async {
        for task in listening { task.cancel() }
        listening = []
        setup?.cancel()
        watching?.cancel()
        watching = nil
    }

    public var declarationChanges: ChangeSignal? { changes }

    // MARK: - Commands

    public var commands: [Command] {
        fixedCommands + catalog.runnable.map { factory.command(for: $0) }
    }

    private var fixedCommands: [Command] {
        [
            Command(
                id: "create", title: Strings.createTitle, icon: .symbol("plus.rectangle.on.folder"),
                keywords: Strings.createKeywords
            ) { [self] _ in
                .push(
                    .form(
                        CreateScriptForm.page(folders: folders.filter(\.isEnabled), library: library) {
                            [weak self] in
                            await self?.watchFolders().value
                        }))
            },
            Command(id: "open-folder", title: Strings.openFolderTitle, icon: .symbol("folder")) {
                [self] context in
                try await library.makeFolder(defaultFolder)
                try await context.workspace.open(defaultFolder)
                await watchFolders().value
                return .close()
            },
            Command(id: "reload", title: Strings.reloadTitle, icon: .symbol("arrow.clockwise")) {
                [self] context in
                await watchFolders().value
                context.showToast(reloadSummary)
                return .keepOpen
            },
            Command(
                id: "manage", title: Strings.manageTitle, icon: .symbol("list.bullet.rectangle"),
                keywords: Strings.manageKeywords
            ) { [self] _ in
                let feature = Self.manifest.id
                let emptyState = EmptyState(
                    icon: .symbol("terminal"), title: Strings.noScriptsTitle, message: Strings.noScriptsMessage,
                    actions: [
                        .runCommand(.command(feature: feature, command: "create"), title: Strings.createTitle),
                        .runCommand(.command(feature: feature, command: "open-folder"), title: Strings.openFolderTitle),
                    ])
                return .push(
                    .list(
                        ListPage(
                            manageList, title: Strings.manageTitle, searchPlaceholder: Strings.manageSearchPlaceholder,
                            showsDetail: true, emptyState: emptyState)))
            },
        ]
    }

    private var reloadSummary: Toast {
        .success(
            Strings.reloaded(commands: catalog.runnable.count),
            message: Strings.reloadProblems(catalog.entries.filter(\.hasErrors).count))
    }

    // MARK: - Settings and status

    public var settingsPane: SettingsPane? {
        SettingsPane([
            SettingsSection(
                Strings.foldersSection,
                items: [
                    .note(Strings.safetyNote),
                    .list(
                        Strings.foldersTitle, key: ScriptsSettings.folders, itemKind: .folder, info: Strings.foldersInfo
                    ),
                    .multiSelect(
                        Strings.enabledFoldersTitle, key: ScriptsSettings.enabledFolders,
                        info: Strings.enabledFoldersInfo
                    ) { [weak self] in
                        self?.folderChoices() ?? []
                    },
                    .toggle(Strings.remoteIconsTitle, key: ScriptsSettings.remoteIcons, info: Strings.remoteIconsInfo),
                    .button(Strings.reloadTitle, info: Strings.reloadButtonInfo) { [weak self] context in
                        guard let self else { return }
                        await watchFolders().value
                        context.showToast(reloadSummary)
                    },
                ]),
            SettingsSection(
                Strings.runningSection,
                items: [
                    .picker(Strings.timeoutTitle, key: ScriptsSettings.timeout, info: Strings.timeoutInfo) {
                        Strings.timeoutName($0)
                    },
                    .picker(Strings.outputLimitTitle, key: ScriptsSettings.outputLimit, info: Strings.outputLimitInfo) {
                        Strings.outputLimitName($0)
                    },
                    .textField(
                        Strings.searchPathTitle, key: ScriptsSettings.searchPath,
                        placeholder: ScriptsSettings.defaultSearchPath, info: Strings.searchPathInfo),
                ]),
            SettingsSection(
                Strings.inlineSection,
                items: [
                    .multiSelect(Strings.inlineTitle, key: ScriptsSettings.refreshingInline, info: Strings.inlineInfo) {
                        [weak self] in
                        self?.inlineChoices() ?? []
                    }
                ]),
        ])
    }

    /// The folders the user added, for turning them on.
    private func folderChoices() -> [SettingsChoice] {
        folders.filter { !$0.isDefault }.map { folder in
            SettingsChoice(id: folder.path, title: displayPath(folder.path), icon: .symbol("folder"))
        }
    }

    /// The inline scripts that can refresh by themselves.
    private func inlineChoices() -> [SettingsChoice] {
        let home = context.storage.homeDirectory
        return catalog.runnable.filter(\.canRefreshByItself).map { script in
            SettingsChoice(
                id: script.commandID, title: script.title,
                icon: script.icon(home: home, allowsRemote: context.settings[ScriptsSettings.remoteIcons]))
        }
    }

    /// A path with the home folder written as `~`.
    private func displayPath(_ path: String) -> String {
        let home = ScriptPath.key(context.storage.homeDirectory)
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    public var status: FeatureStatus? {
        if let missing = catalog.folders.first(where: { !$0.exists && !$0.folder.isDefault }) {
            return FeatureStatus(.warning, Strings.missingFolderStatus(displayPath(missing.folder.path)))
        }
        let problems = catalog.entries.filter(\.hasErrors).count
        if problems > 0 {
            return FeatureStatus(.warning, Strings.problemsStatus(problems), message: Strings.problemsStatusMessage)
        }
        let off = catalog.entries.filter { !$0.folder.isEnabled }.count
        if off > 0 {
            return FeatureStatus(.info, Strings.offStatus(off), message: Strings.offStatusMessage)
        }
        return nil
    }

    // MARK: - Folders

    /// Turns a folder the user added on, so its scripts become commands.
    func enableFolder(_ path: String) async {
        let home = context.storage.homeDirectory
        let target = Self.normalize(path, home: home)
        var enabled = context.settings[ScriptsSettings.enabledFolders]
        if !enabled.contains(where: { Self.normalize($0, home: home) == target }) {
            enabled.append(target)
            context.settings[ScriptsSettings.enabledFolders] = enabled
        }
        await watchFolders().value
    }

    private func settingChanged(_ name: String) async {
        switch name {
        case ScriptsSettings.folders.name:
            forgetRemovedFolders()
            await watchFolders().value
        case ScriptsSettings.enabledFolders.name:
            await watchFolders().value
        case ScriptsSettings.remoteIcons.name:
            // Commands and Manage Script Commands show the icons again.
            changes.send()
        default:
            // Automatic refresh turned on or off: inline subtitles read the setting again now.
            for script in catalog.runnable where script.mode == .inline {
                subtitles.signal(for: script.commandID).send()
            }
        }
    }

    /// Drops removed folders from the folders that may run, so a folder added again later starts
    /// off.
    private func forgetRemovedFolders() {
        let home = context.storage.homeDirectory
        let listed = Set(context.settings[ScriptsSettings.folders].map { Self.normalize($0, home: home) })
        let enabled = context.settings[ScriptsSettings.enabledFolders]
        let kept = enabled.filter { listed.contains(Self.normalize($0, home: home)) }
        if kept != enabled { context.settings[ScriptsSettings.enabledFolders] = kept }
    }

    /// The default folder, then each folder from settings once, marked on or off.
    private func currentFolders() -> [ScriptFolder] {
        let home = context.storage.homeDirectory
        let enabled = Set(context.settings[ScriptsSettings.enabledFolders].map { Self.normalize($0, home: home) })
        var result = [ScriptFolder(url: defaultFolder, isDefault: true, isEnabled: true)]
        var seen: Set<String> = [result[0].path]
        for raw in context.settings[ScriptsSettings.folders] {
            let path = Self.normalize(raw, home: home)
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            result.append(
                ScriptFolder(
                    url: URL(filePath: path, directoryHint: .isDirectory), isDefault: false,
                    isEnabled: enabled.contains(path)))
        }
        return result
    }

    /// A folder path from settings as a comparable key. Relative paths are ignored.
    nonisolated static func normalize(_ raw: String, home: URL) -> String {
        let path = raw.trimmed
        guard path.hasPrefix("/") || path == "~" || path.hasPrefix("~/") else { return "" }
        return ScriptPath.key(ScriptPath.resolve(path, folder: home, home: home))
    }

    // MARK: - Scanning

    /// Reads the folders from settings, watches them, replacing any earlier watch, and scans them.
    @discardableResult
    func watchFolders() -> Task<Void, Never> {
        watching?.cancel()
        folders = currentFolders()
        let events = context.fileWatcher.watch(folders.map(\.url))
        watching = Task { [weak self] in
            for await _ in events { await self?.rescan().value }
        }
        return rescan()
    }

    /// Scans every folder again and sends ``changes`` when the result differs. The returned task
    /// ends when this scan has applied.
    @discardableResult
    func rescan() -> Task<Void, Never> {
        let previous = scan
        let (folders, library) = (folders, library)
        let task = Task {
            await previous?.value
            let listings = await library.listings(of: folders.map(\.url))
            let found = await ScriptCatalog.build(listings, folders: folders)
            // The folders changed while this scan ran; the scan for the new folders applies instead.
            guard folders == self.folders, found != catalog else { return }
            catalog = found
            context.log.info("Found \(found.entries.count) scripts, \(found.runnable.count) runnable")
            changes.send()
        }
        scan = task
        return task
    }

    /// Returns once the first scan and any scan started meanwhile have applied.
    func scanned() async {
        await setup?.value
        while let current = scan {
            await current.value
            if scan == current { return }
        }
    }
}
