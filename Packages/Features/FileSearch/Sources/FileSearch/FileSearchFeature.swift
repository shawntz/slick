import CoreBridge
import Foundation
import Kit
import os

/// File search over the launcher's own index of file names.
///
/// - The index is the Rust core's file index, owned by ``IndexController``: opened or walked off
///   the main thread, fed batches of events from Kit's file watcher on one queue, and saved at
///   quiet moments and when the feature stops, with the mark the watcher resumes from at the next
///   start. A walk stops when the feature stops.
/// - The feature is off until the user turns it on, because indexing the names in the home folder
///   reads personal data. Onboarding suggests it with its switch on.
/// - Root search gets a Files section and folder browsing from ``RootFiles``. The Search Files page
///   is ``SearchFilesList``. Each searches on its own ``SearchLane`` at user-initiated priority, so
///   a keystroke never waits for the main thread until its rows are ready. A typed folder the index
///   does not hold is listed from disk when ``BrowseGuard`` allows it.
/// - The scope starts with the home folder, without Library and without the places macOS guards.
///   A protected place joins only after the user asks for it, one at a time or all at once. Full
///   Disk Access only spares the prompt. A place whose folder cannot be read is left out until the
///   user asks again. See ``ScopePlan`` and ``PlaceChoices``.
/// - Every disk access goes through two services of the feature's own, ``IndexMaker`` and
///   ``FileSystem``, with a live implementation and an isolated one each.
public final class FileSearchFeature: Feature {
    public static let manifest = FeatureManifest(
        id: "files", name: Strings.featureName, icon: .symbol("doc.text.magnifyingglass"), summary: Strings.summary,
        permissions: [
            PermissionNeed(.protectedFolder(.desktop), reason: Strings.Permissions.desktop),
            PermissionNeed(.protectedFolder(.documents), reason: Strings.Permissions.documents),
            PermissionNeed(.protectedFolder(.downloads), reason: Strings.Permissions.downloads),
            PermissionNeed(.protectedFolder(.iCloudDrive), reason: Strings.Permissions.iCloudDrive),
            PermissionNeed(.protectedFolder(.removableVolumes), reason: Strings.Permissions.removableVolumes),
            PermissionNeed(.protectedFolder(.networkVolumes), reason: Strings.Permissions.networkVolumes),
            PermissionNeed(.fullDiskAccess, reason: Strings.Permissions.fullDiskAccess),
        ],
        isEnabledByDefault: false, isSuggestedInOnboarding: true)

    /// The index file's name in the feature's data folder.
    nonisolated static let indexFileName = "file-index.bin"

    let context: FeatureContext
    let controller: IndexController
    let fileSystem: any FileSystem
    let rootLane: SearchLane
    let pageLane: SearchLane
    let fileActions: FileActions
    /// Sent when a declaration changed: the status, the pane's text, the root search switch.
    let declarations = ChangeSignal()

    private(set) lazy var rootFiles = RootFiles(
        controller: controller, lane: rootLane, fileSystem: fileSystem, actions: fileActions)
    private(set) lazy var searchList = SearchFilesList(feature: self)
    private(set) lazy var placesList = PlacesList(feature: self)

    private var isActive = false
    private var listeners: [Task<Void, Never>] = []
    private var loadTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private(set) var watchedRoots: [String] = []
    /// Moves on with every watch, so a watch that ended late cannot mark a newer one as stopped.
    private var watchGeneration = 0
    /// The watcher's stream ended by itself: macOS refused or stopped reporting changes.
    private(set) var watchStopped = false
    private var scopeTask: Task<Void, Never>?
    private var scopeIsStale = false
    private var accessWaits: [ProtectedPlace: Task<Void, Never>] = [:]

    /// Does no I/O. The index opens in ``activate()``, off the main thread.
    public init(context: FeatureContext) {
        self.context = context
        fileSystem = context.service(FileSystemKey.self)
        let permissions = context.permissions
        controller = IndexController(
            file: context.storage.dataFile(Self.indexFileName).path(percentEncoded: false),
            maker: context.service(IndexMakerKey.self), clock: context.clock, log: context.log,
            mayRead: { place in
                place.isReadable(
                    isGranted: { permissions.isGranted($0) }, fullDiskAccess: permissions.isGranted(.fullDiskAccess))
            })
        rootLane = SearchLane(
            label: "files.search.root", clock: context.clock, searchCapacity: 24, browseCapacity: 1_000)
        pageLane = SearchLane(
            label: "files.search.page", clock: context.clock, searchCapacity: 400, browseCapacity: 2_000)
        fileActions = FileActions(controller: controller)
    }

    // MARK: - Declarations

    public var declarationChanges: ChangeSignal? { declarations }

    public var liveProviders: [LiveProvider] {
        context.settings[FileSearchSettings.showsInRoot] ? [.async(rootFiles)] : []
    }

    public var commands: [Command] {
        [searchCommand, rebuildCommand, chooseFoldersCommand]
    }

    public var status: FeatureStatus? {
        let summary = controller.summary
        if summary.phase == .failed {
            return FeatureStatus(.failure, Strings.Status.failed, message: Strings.Status.failedMessage)
        }
        let blocked = blockedPlaces()
        if !blocked.isEmpty {
            let states = placeStates()
            let missing = blocked.compactMap(\.permission).filter { !context.permissions.isGranted($0) }
            return FeatureStatus(
                .warning, Strings.Status.blockedTitle(blocked),
                message: Strings.Status.blockedMessage(
                    waiting: blocked.filter { states[$0] == .waitingForAccess },
                    refused: blocked.filter { states[$0] == .accessDenied }),
                requires: missing)
        }
        if watchStopped {
            return FeatureStatus(.warning, Strings.Status.notFollowing, message: Strings.Status.notFollowingMessage)
        }
        if summary.phase == .building {
            return FeatureStatus(.info, Strings.Status.building, message: Strings.Status.buildingMessage)
        }
        if summary.rebuiltAfterDamage {
            return FeatureStatus(.info, Strings.Status.damaged, message: Strings.Status.damagedMessage)
        }
        return nil
    }

    // MARK: - Commands

    private var searchCommand: Command {
        Command(
            id: "search", title: Strings.Commands.search, icon: .symbol("doc.text.magnifyingglass"),
            keywords: Strings.Commands.searchKeywords, fallback: Fallback(title: Strings.Commands.fallback),
            takesRootQueryOnTab: true
        ) { [self] context in
            let typed = context.launch == .fallback || context.launch == .tabFromRoot ? context.query : ""
            return .push(
                .list(
                    ListPage(
                        searchList, searchPlaceholder: Strings.Commands.searchPlaceholder,
                        filter: SearchFilesList.dropdown, showsDetail: true, initialQuery: typed)))
        }
    }

    private var rebuildCommand: Command {
        Command(
            id: "rebuild", title: Strings.Commands.rebuild, icon: .symbol("arrow.clockwise"),
            keywords: Strings.Commands.rebuildKeywords,
            liveSubtitle: LiveSubtitle(every: .seconds(30), changes: controller.stateChanges) { [weak self] in
                self.map { LiveSubtitle.Value($0.summaryLine) }
            },
            runPolicy: .dropWhileRunning
        ) { [self] context in
            let toast = context.showToast(.progress(Strings.Index.rebuilding))
            let outcome = await rebuild()
            if outcome.failed {
                toast.update(.failure(Strings.Index.rebuildFailed, message: Strings.Index.rebuildFailedMessage))
            } else {
                let locale = self.context.clock.locale
                toast.update(
                    .success(
                        Strings.Index.rebuilt, message: Strings.Index.holds(controller.summary.count, locale: locale)))
            }
            return .keepOpen
        }
    }

    private var chooseFoldersCommand: Command {
        Command(
            id: "choose-folders", title: Strings.Commands.chooseFolders, icon: .symbol("folder.badge.gearshape"),
            keywords: Strings.Commands.chooseKeywords
        ) { [self] _ in
            .push(choosePage)
        }
    }

    var choosePage: Page {
        .list(
            ListPage(
                placesList, title: Strings.Commands.chooseFolders, searchPlaceholder: Strings.Commands.choosePlaceholder
            ))
    }

    /// The status line: how many items the index holds and when it last changed.
    var summaryLine: String {
        let summary = controller.summary
        switch summary.phase {
        case .idle: return Strings.Index.notBuilt
        case .failed: return Strings.Index.failed
        case .building: return Strings.Index.building
        case .ready:
            guard let updated = summary.updatedAt else { return Strings.Index.notBuilt }
            return Strings.Index.summary(
                count: summary.count, updated: updated, now: context.clock.now, locale: context.clock.locale)
        }
    }

    // MARK: - Lifecycle

    /// Opens the saved index or walks the scope in the background, and starts following file events,
    /// settings and the permissions the user is waiting for. Returns at once. Nothing here can
    /// raise a prompt: the scope holds only places that raise none, or that the user granted.
    public func activate() async {
        stopTasks()
        isActive = true
        let scopeChanges = context.settings.changes(ofAny: FileSearchSettings.scopeKeys)
        let rootSwitch = context.settings.changes(of: FileSearchSettings.showsInRoot)
        let indexStates = controller.stateChanges.stream()
        listeners = [
            Task { [weak self] in
                for await _ in scopeChanges { self?.requestScopeRefresh() }
            },
            Task { [weak self] in
                for await _ in rootSwitch { self?.declarations.send() }
            },
            Task { [weak self] in
                for await _ in indexStates { self?.indexStateChanged() }
            },
        ]
        loadTask = Task { [weak self] in await self?.start() }
    }

    /// Stops following events, saves what changed and lets the index go. The file stays.
    public func deactivate() async {
        isActive = false
        stopTasks()
        await controller.close()
        await rootLane.close()
        await pageLane.close()
        declarations.send()
    }

    private func start() async {
        let plan = await makePlan()
        guard isActive else { return }
        let outcome: LoadOutcome?
        if controller.index == nil {
            // The watch starts before the index opens, so nothing that changes meanwhile is missed.
            // With the saved mark it first replays what changed while the feature was off.
            let mark = await controller.savedMark()
            guard isActive else { return }
            startWatching(plan.roots, since: mark)
            outcome = await controller.load(plan, resuming: mark)
        } else {
            startWatching(plan.roots)
            outcome = await controller.rescope(plan)
        }
        guard isActive else { return }
        reconcile(outcome?.unreadable ?? [])
        syncAccessWaits()
        declarations.send()
    }

    private func stopTasks() {
        for task in listeners { task.cancel() }
        listeners = []
        loadTask?.cancel()
        loadTask = nil
        watchTask?.cancel()
        watchTask = nil
        watchedRoots = []
        watchStopped = false
        scopeTask?.cancel()
        scopeTask = nil
        scopeIsStale = false
        for task in accessWaits.values { task.cancel() }
        accessWaits = [:]
    }

    /// Starts one watch over the roots, from `mark` when given. File events go straight to the
    /// index queue; the main thread never sees them.
    private func startWatching(_ roots: [String], since mark: FileChangeMark? = nil) {
        let directories = roots.map { URL(filePath: $0, directoryHint: .isDirectory) }
        follow(context.fileWatcher.watchChanges(directories, since: mark), roots: roots)
    }

    /// Hands each batch of `changes` to the index. A stream that ends while the feature still
    /// follows it means macOS stopped reporting changes, which the status then says.
    func follow(_ changes: AsyncStream<FileChangeBatch>, roots: [String]) {
        watchTask?.cancel()
        watchedRoots = roots
        watchGeneration += 1
        watchStopped = false
        let generation = watchGeneration
        let controller = controller
        watchTask = Task.detached(priority: .utility) { [weak self] in
            for await batch in changes { controller.submit(batch) }
            guard !Task.isCancelled else { return }
            await self?.watchEnded(generation)
        }
    }

    private func watchEnded(_ generation: Int) {
        guard isActive, generation == watchGeneration else { return }
        context.log.error("The file watcher stopped; changes are no longer followed")
        watchStopped = true
        declarations.send()
    }

    /// Waits until the work started so far has finished: the first open, scope changes and
    /// everything queued for the index. For tests and the rebuild command.
    func waitUntilIdle() async {
        await loadTask?.value
        while let scopeTask {
            await scopeTask.value
        }
        await controller.waitUntilIdle()
    }

    // MARK: - Scope

    /// Where each protected place stands now. Reading permission statuses never prompts.
    func placeStates(_ choices: PlaceChoices? = nil) -> [ProtectedPlace: PlaceState] {
        let choices = choices ?? PlaceChoices(context.settings)
        let permissions = context.permissions
        return choices.states(
            isGranted: { permissions.isGranted($0) }, fullDiskAccess: permissions.isGranted(.fullDiskAccess))
    }

    /// The scope as the settings and permissions say now. Volumes are listed only when the user
    /// chose to search a kind of volume.
    func makePlan() async -> ScopePlan {
        let states = placeStates()
        let home = Paths.normalized(context.storage.homeDirectory.path(percentEncoded: false), home: nil) ?? "/"
        let settings = context.settings
        var input = ScopeInput(
            home: home, states: states, extraFolders: settings[FileSearchSettings.extraFolders],
            excludedFolders: settings[FileSearchSettings.excludedFolders],
            excludedNames: settings[FileSearchSettings.excludedNames],
            includesHidden: settings[FileSearchSettings.includesHidden])
        if states[.removableVolumes] == .searched || states[.networkVolumes] == .searched {
            input.volumes = await fileSystem.mountedVolumes()
        }
        return ScopePlan(input)
    }

    /// Follows the settings and permissions after a change. Changes that arrive while one is being
    /// applied are applied together after it.
    func requestScopeRefresh() {
        guard isActive else { return }
        scopeIsStale = true
        guard scopeTask == nil else { return }
        scopeTask = Task { [weak self] in
            await self?.loadTask?.value
            while let self, self.scopeIsStale, self.isActive {
                self.scopeIsStale = false
                await self.applyScope()
            }
            self?.scopeTask = nil
        }
    }

    private func applyScope() async {
        let plan = await makePlan()
        guard isActive else { return }
        if plan.roots != watchedRoots || watchStopped { startWatching(plan.roots) }
        if let outcome = await controller.rescope(plan) { reconcile(outcome.unreadable) }
        syncAccessWaits()
        declarations.send()
    }

    /// Reads the permission statuses again when the Search Files page opens, so a grant made in
    /// System Settings, such as Full Disk Access, takes effect without a stream left open for it.
    func recheckAccess() {
        guard isActive, let plan = controller.plan else { return }
        let searched = Set(placeStates().filter { $0.value == .searched }.map(\.key))
        if searched != Set(plan.placeFolders.keys) { requestScopeRefresh() }
    }

    /// Records places whose folders could not be read, so they are not read again. Places the user
    /// did not ask for, such as a missing iCloud Drive under Full Disk Access, are recorded the
    /// same way but never shown as a problem.
    private func reconcile(_ unreadable: Set<ProtectedPlace>) {
        guard !unreadable.isEmpty else { return }
        var choices = PlaceChoices(context.settings)
        let states = placeStates(choices)
        let newly = unreadable.filter { states[$0] == .searched }
        guard !newly.isEmpty else { return }
        choices.denied.formUnion(newly)
        choices.save(to: context.settings)
    }

    private func indexStateChanged() {
        let summary = controller.summary
        reconcile(summary.unreadable)
        // A permission went away while the feature ran: follow the scope the permissions allow now,
        // which leaves the place out and waits for a new grant.
        if !summary.accessLost.isEmpty { requestScopeRefresh() }
        declarations.send()
    }

    /// Places the user asked for that are not searched for want of access.
    func blockedPlaces() -> [ProtectedPlace] {
        let choices = PlaceChoices(context.settings)
        let states = placeStates(choices)
        return ProtectedPlace.allCases.filter { place in
            choices.included.contains(place) && (states[place] == .waitingForAccess || states[place] == .accessDenied)
        }
    }

    /// Opens a permission stream for each place the user asked for whose permission is missing,
    /// and closes the others. A grant made in System Settings then brings the place in; a grant made
    /// in the launcher arrives through ``permissionGranted(_:)``. Nothing is opened at idle, and
    /// nothing for iCloud Drive, whose status changes only when the launcher asks.
    private func syncAccessWaits() {
        var wanted: [ProtectedPlace: Permission] = [:]
        for place in blockedPlaces() where place.fullDiskAccessCovers {
            guard let permission = place.permission, !context.permissions.isGranted(permission) else { continue }
            wanted[place] = permission
        }
        for (place, task) in accessWaits where wanted[place] == nil {
            task.cancel()
            accessWaits[place] = nil
        }
        for (place, permission) in wanted where accessWaits[place] == nil {
            let changes = context.permissions.changes(of: permission)
            accessWaits[place] = Task { [weak self] in
                for await status in changes where status.isGranted {
                    self?.accessGranted(place)
                }
            }
        }
    }

    /// The user granted a place's permission while the feature waited for it.
    private func accessGranted(_ place: ProtectedPlace) {
        accessWaits[place]?.cancel()
        accessWaits[place] = nil
        var choices = PlaceChoices(context.settings)
        choices.denied.remove(place)
        choices.save(to: context.settings)
        requestScopeRefresh()
    }

    /// The number of permission streams open now. For tests.
    var openAccessWaits: Int { accessWaits.count }

    /// A grant made in the settings window, onboarding or the panel's permission card brings in the
    /// places the user asked for that it covers, and reads again one whose read had failed.
    public func permissionGranted(_ permission: Permission) async {
        guard isActive else { return }
        let covers = permission == .fullDiskAccess
        let included = PlaceChoices(context.settings).included
        for place in ProtectedPlace.allCases where included.contains(place) {
            if place.permission == permission || (covers && place.fullDiskAccessCovers) { accessGranted(place) }
        }
    }

    // MARK: - Choosing places

    /// Records that the user asked to search these places and follows the new scope.
    func includePlaces(_ places: [ProtectedPlace]) {
        var choices = PlaceChoices(context.settings)
        choices.include(places)
        choices.save(to: context.settings)
        requestScopeRefresh()
    }

    /// Records that the user asked not to search this place and follows the new scope.
    func turnOff(_ place: ProtectedPlace) {
        var choices = PlaceChoices(context.settings)
        choices.turnOff(place)
        choices.save(to: context.settings)
        requestScopeRefresh()
    }

    /// Asks macOS for each place's permission that is missing, one after another. Full Disk Access
    /// spares every prompt but iCloud Drive's. Only an action or a settings button calls this, right
    /// after the user pressed it.
    func askForAccess(_ places: [ProtectedPlace], context actionContext: ActionContext) async {
        let permissions = context.permissions
        let fullDiskAccess = permissions.isGranted(.fullDiskAccess)
        for place in places {
            guard let permission = place.permission,
                !place.isReadable(isGranted: { permissions.isGranted($0) }, fullDiskAccess: fullDiskAccess)
            else { continue }
            _ = await actionContext.requestPermission(permission)
        }
    }

    /// The toast after the user chose a place.
    private func toast(afterChoosing place: ProtectedPlace) -> Toast {
        switch placeStates()[place] ?? .notSearched {
        case .searched: .success(Strings.Places.searching(place))
        default: Toast(.info, Strings.Places.needsAccess(place), message: Strings.Places.needsAccessMessage)
        }
    }

    /// The actions for one place on the Choose Folders to Search page. Searching a place declares
    /// its permission, so the host explains and asks before the handler runs.
    func placeActions(for place: ProtectedPlace) -> [Action] {
        if placeStates()[place] == .searched {
            return [
                Action(Strings.Places.stop(place), id: "stop", icon: .symbol("minus.circle")) { [self] context in
                    turnOff(place)
                    context.showToast(.success(Strings.Places.stopped(place)))
                    return .keepOpen
                }
            ]
        }
        return [
            Action(
                Strings.Places.search(place), id: "search", icon: .symbol("plus.circle"),
                confirmation: place == .iCloudDrive ? Strings.Places.iCloudConfirmation : nil,
                requires: place.permission.map { [$0] } ?? []
            ) { [self] context in
                includePlaces([place])
                context.showToast(toast(afterChoosing: place))
                return .keepOpen
            }
        ]
    }

    /// Asks for Desktop, Documents, Downloads and iCloud Drive in turn after one confirmation.
    func searchAllAction() -> Action {
        Action(
            Strings.Places.searchAll, id: "search-all", icon: .symbol("plus.circle"),
            confirmation: Strings.Places.searchAllConfirmation
        ) { [self] context in
            await askForAccess(ProtectedPlace.folders, context: context)
            includePlaces(ProtectedPlace.folders)
            context.showToast(.success(Strings.Places.searchingAll))
            return .keepOpen
        }
    }

    /// The banner on the Search Files page: a walk in progress, places that could not be read, or
    /// the protected folders that are not searched yet.
    func notice() -> Notice? {
        let summary = controller.summary
        let choose = Action.push(Strings.Page.chooseFolders, id: "choose-folders", icon: .symbol("folder.badge.plus")) {
            [self] in choosePage
        }
        let blocked = blockedPlaces()
        if !blocked.isEmpty {
            let states = placeStates()
            let refused = blocked.filter { states[$0] == .accessDenied }
            let icon = Icon.symbol("exclamationmark.triangle", tint: .orange)
            if !refused.isEmpty {
                return Notice(
                    icon: icon, title: Strings.Page.unreadableTitle(refused),
                    message: Strings.Page.unreadableMessage(refused), action: choose)
            }
            return Notice(
                icon: icon, title: Strings.Page.waitingTitle(blocked), message: Strings.Page.waitingMessage(blocked),
                action: choose)
        }
        if summary.isWalking && summary.phase == .ready {
            return Notice(
                icon: .symbol("arrow.triangle.2.circlepath"), title: Strings.Page.updatingTitle,
                message: Strings.Page.updatingMessage)
        }
        let states = placeStates()
        let missing = [ProtectedPlace.desktop, .documents, .downloads].filter { states[$0] == .notSearched }
        guard !missing.isEmpty else { return nil }
        return Notice(
            icon: .symbol("lock"), title: Strings.Page.notSearchedTitle(missing),
            message: Strings.Page.notSearchedMessage, action: choose)
    }

    // MARK: - Rebuilding

    /// Reads the permissions and volumes again, then walks every root. A scope that changed is
    /// walked into a new index instead.
    func rebuild() async -> LoadOutcome {
        await waitUntilIdle()
        guard isActive else { return LoadOutcome(failed: true) }
        let plan = await makePlan()
        if plan.roots != watchedRoots || watchStopped { startWatching(plan.roots) }
        let outcome: LoadOutcome
        if let rescoped = await controller.rescope(plan) {
            outcome = rescoped
        } else {
            outcome = await controller.rebuild()
        }
        reconcile(outcome.unreadable)
        syncAccessWaits()
        declarations.send()
        return outcome
    }
}
