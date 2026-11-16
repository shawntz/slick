import Foundation
import Kit
import Synchronization
import os

/// Which app a list searches.
nonisolated enum MenuTarget: Hashable, Sendable {
    case app(MenuApp)
    /// The app in front is one the user chose to leave out.
    case leftOut(MenuApp)
    /// No app was in front, or the launcher itself was.
    case none

    /// The target for the app that was in front when the launcher opened. Bundle IDs compare
    /// without case, as macOS compares them, and without spaces at either end of a typed entry.
    static func resolve(_ info: AppInfo?, leftOut: [String]) -> MenuTarget {
        guard let info, !info.bundleID.isEmpty, !sameBundleID(info.bundleID, Brand.bundleID) else { return .none }
        let app = MenuApp(bundleID: info.bundleID, name: info.name.isEmpty ? info.bundleID : info.name)
        return leftOut.contains { sameBundleID($0, info.bundleID) } ? .leftOut(app) : .app(app)
    }

    private static func sameBundleID(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(rhs) == .orderedSame
    }
}

/// The Search Menu Items page: every menu item of one app.
///
/// - The page never waits for a read. A load returns at once: the cached menus when there are any,
///   or a "Reading Menus" state. A read runs in a task of its own and sends ``changes`` when it ends,
///   so the host loads again.
/// - Each time the page opens or shows again after the panel closed, it reads the menus afresh in
///   the background, so the cache shown at once does not go stale. It learns of both through
///   ``PageEvents``.
/// - It follows the app in front: a page left open from an earlier summon switches to the app that
///   was in front this time.
/// - Filtering is the source's own: the search and the rows run off the main thread, a page of
///   ``MenuRows/pageSize`` at a time.
/// - A read stops when the panel closes, when its time limit passes and when the page goes away.
/// - The page is busy while a read runs, through ``BusySource``, so a scenario's idle wait sees the
///   read that the "Reading Menus" state stands for.
final class MenuItemList: ListSource, PageEvents, BusySource {
    let filtering = ListFiltering.custom(debounce: .milliseconds(20))
    let changes: ChangeSignal? = ChangeSignal()
    var reloadsOnSettings: [AnySettingKey] { MenuItemsSettings.listKeys }

    private let context: FeatureContext
    private let reader: any MenuReader
    private let cache: MenuCache
    private let limits: WalkLimits
    private(set) var target: MenuTarget
    /// The read running now, if any.
    private var read: Task<Void, Never>?
    /// Counts reads started, so a read that ends after a newer one started changes nothing.
    private var readGeneration = 0
    /// True when the next load should start a fresh read.
    private var needsFreshRead = true
    /// Why the last read failed, until the next one starts.
    private(set) var failure: MenuReadError?
    /// The progress toast of Read Menus Again, dismissed when the read ends.
    private var readToast: ToastHandle?
    /// Tasks that must not outlive the page.
    private let tasks = TaskBag()

    init(target: MenuTarget, context: FeatureContext, reader: any MenuReader, cache: MenuCache, limits: WalkLimits) {
        self.target = target
        self.context = context
        self.reader = reader
        self.cache = cache
        self.limits = limits
    }

    deinit {
        tasks.cancelAll()
    }

    /// True while a read runs.
    var isReading: Bool { read != nil }

    /// Kit's ``BusySource``: busy exactly while a read runs.
    var isBusy: Bool { isReading }

    /// Returns once the read running now, if any, has ended and its result is in the cache.
    func readFinished() async {
        await read?.value
    }

    // MARK: - Loading

    func load(_ request: ListRequest) async throws -> ListResult {
        let isFirstPage = request.page == nil
        if isFirstPage, request.reason != .query { followFrontmostApp() }
        guard case .app(let app) = target else { return ListResult(sections: [], emptyState: emptyState(for: target)) }
        if isFirstPage, request.reason != .query, needsFreshRead, read == nil { startRead(app) }

        if let failure, Self.hidesCache(failure) {
            return ListResult(sections: [], emptyState: emptyState(for: failure, app: app))
        }
        guard let entry = cache.entry(for: app.bundleID) else {
            if let failure { return ListResult(sections: [], emptyState: emptyState(for: failure, app: app)) }
            return ListResult(
                sections: [],
                emptyState: EmptyState(
                    icon: .symbol("hourglass"), title: Strings.readingTitle, message: Strings.readingMessage(app.name)))
        }
        let query = request.query
        let index: (any FuzzyIndex)? = query.isEmpty ? nil : await entry.index.value
        try Task.checkCancellation()
        let offset = request.page.flatMap { Int($0.value) } ?? 0
        let page = await MenuRows.page(
            MenuRows.Request(
                snapshot: entry.snapshot, index: index, query: query,
                options: MenuItemsSettings.options(context.settings), offset: offset))
        try Task.checkCancellation()
        return ListResult(
            sections: page.sections,
            emptyState: page.total == 0 ? emptyState(for: entry.snapshot, query: query) : nil,
            nextPage: page.nextOffset.map { ListPageToken(String($0)) },
            notice: isFirstPage ? notice(for: entry.snapshot) : nil)
    }

    // MARK: - Reading

    /// Starts a fresh read of the menus in the background.
    private func startRead(_ app: MenuApp) {
        needsFreshRead = false
        failure = nil
        readGeneration += 1
        let generation = readGeneration
        let reader = reader
        let limits = limits
        let previous = cache.entry(for: app.bundleID)
        let started = context.clock.now
        read = Task { [weak self] in
            let result: Result<MenuSnapshot, MenuReadError>
            do {
                result = .success(try await reader.readMenus(of: app, limits: limits))
            } catch let error as MenuReadError {
                result = .failure(error)
            } catch {
                result = .failure(.notAnswering)
            }
            var unchanged: Int?
            if case .success(let snapshot) = result, let previous,
                await Self.same(previous.snapshot, snapshot)
            {
                unchanged = previous.generation
            }
            self?.finishRead(app, result, generation: generation, unchangedSince: unchanged, started: started)
        }
        tasks.add(read)
    }

    private func finishRead(
        _ app: MenuApp, _ result: Result<MenuSnapshot, MenuReadError>, generation: Int, unchangedSince: Int?,
        started: Date
    ) {
        guard generation == readGeneration else { return }
        read = nil
        readToast?.dismiss()
        readToast = nil
        guard target == .app(app) else { return }
        switch result {
        case .success(let snapshot):
            let elapsed = context.clock.now.timeIntervalSince(started)
            context.log.debug(
                "Read \(snapshot.items.count) menu items in \(Int(elapsed * 1000)) ms, ending \(String(describing: snapshot.ending), privacy: .public)"
            )
            // A read the panel's closing stopped is read again the next time the page shows,
            // which the signal makes the host load.
            let stopped = snapshot.ending == .stopped
            if stopped { needsFreshRead = true }
            let changed = cache.store(snapshot, fuzzy: context.fuzzyIndex, unchangedSince: unchangedSince)
            if changed || stopped { changes?.send() }
        case .failure(let error):
            context.log.debug("Reading menus failed: \(String(describing: error), privacy: .public)")
            failure = error
            if error == .appQuit || error == .appNotRunning || error == .noMenuBar { cache.remove(app.bundleID) }
            changes?.send()
        }
    }

    /// Reads the menus again now, from Read Menus Again.
    func readAgain(_ context: ActionContext) {
        guard case .app(let app) = target else { return }
        if read == nil {
            startRead(app)
            readToast = context.showToast(.progress(Strings.readingTitle))
        }
        changes?.send()
    }

    // MARK: - Page events

    /// The panel closed: stop reading, and read afresh the next time the page shows. A running read
    /// signals when it ends.
    func panelDidClose() {
        needsFreshRead = true
        read?.cancel()
    }

    /// The page shows again, after the panel opened or the user came back to it. The signal makes
    /// the host load it once, which follows the app in front and starts the fresh read.
    func pageWillShowAgain(_ reason: PageShowReason) {
        if needsFreshRead { changes?.send() }
    }

    /// Stops everything, as when the feature turns off.
    func stop() {
        read?.cancel()
        tasks.cancelAll()
    }

    /// A page left open shows again for whichever app was in front when the launcher opened.
    private func followFrontmostApp() {
        let leftOut = context.settings[MenuItemsSettings.leftOutApps]
        let now = MenuTarget.resolve(context.workspace.frontmostApplication(), leftOut: leftOut)
        if case .leftOut(let app) = now { cache.remove(app.bundleID) }
        guard now != target else { return }
        target = now
        read?.cancel()
        read = nil
        readGeneration += 1
        readToast?.dismiss()
        readToast = nil
        failure = nil
        needsFreshRead = true
    }

    @concurrent private nonisolated static func same(_ lhs: MenuSnapshot, _ rhs: MenuSnapshot) async -> Bool {
        lhs == rhs
    }

    /// Failures after which the cached rows would mislead: nothing can be pressed.
    private static func hidesCache(_ failure: MenuReadError) -> Bool {
        switch failure {
        case .accessMissing, .appQuit, .appNotRunning, .noMenuBar: true
        case .notAnswering, .itemGone, .itemDisabled, .elementFailed: false
        }
    }

    // MARK: - Actions

    func actions(for row: Row) -> [Action] {
        guard let payload = Self.payload(of: row) else { return [readAgainAction] }
        var actions = [
            runAction(
                payload.item, itemTitle: payload.title, appName: payload.appName, isEnabled: payload.isEnabled,
                id: "run", title: Strings.runItem, shortcut: nil)
        ]
        if let alternate = payload.optionAlternate {
            actions.append(
                runAction(
                    alternate.item, itemTitle: alternate.title, appName: payload.appName,
                    isEnabled: alternate.isEnabled, id: "run-option-alternate",
                    title: Strings.runAlternate(alternate.title), shortcut: KeyCombo(.return, .option)))
        }
        actions.append(readAgainAction)
        return actions
    }

    /// The row's payload, or one rebuilt from its ID and title when the payload is gone. The title
    /// goes into the reference, so a press checks the item at that place is still the one the row
    /// showed and never presses whatever moved there.
    static func payload(of row: Row) -> MenuRowPayload? {
        if let payload = try? row.payload?.decode(MenuRowPayload.self) { return payload }
        guard let ref = MenuItemRef(key: row.id.key, title: MenuWalker.cleanTitle(row.title)) else { return nil }
        return MenuRowPayload(item: ref, title: row.title, appName: ref.bundleID, isEnabled: true)
    }

    /// Closes the launcher, lets the app come back to the front, then presses the item.
    private func runAction(
        _ item: MenuItemRef, itemTitle: String, appName: String, isEnabled: Bool, id: String, title: String,
        shortcut: KeyCombo?
    ) -> Action {
        let reader = reader
        return Action(
            title, id: id, icon: .symbol("filemenu.and.selection"), shortcut: shortcut, requires: [.accessibility],
            runPolicy: .dropWhileRunning
        ) { [weak self] context in
            guard isEnabled else {
                context.showToast(.failure(Strings.unavailableTitle, message: Strings.unavailableMessage(appName)))
                return .keepOpen
            }
            context.dismiss()
            self?.panelDidClose()
            do {
                try await reader.press(item)
            } catch let error as MenuReadError {
                throw Self.pressFailure(error, itemTitle: itemTitle, appName: appName)
            }
            return .close()
        }
    }

    static func pressFailure(_ error: MenuReadError, itemTitle: String, appName: String) -> ActionFailure {
        switch error {
        case .accessMissing:
            ActionFailure(Strings.needsAccessTitle, message: Strings.needsAccessPressMessage)
        case .appQuit, .appNotRunning:
            ActionFailure(Strings.couldNotRun(itemTitle), message: Strings.appGoneMessage(appName))
        case .itemGone:
            ActionFailure(Strings.couldNotRun(itemTitle), message: Strings.itemGoneMessage(appName))
        case .itemDisabled:
            ActionFailure(Strings.couldNotRun(itemTitle), message: Strings.itemDisabledMessage(appName))
        case .notAnswering, .noMenuBar, .elementFailed:
            ActionFailure(Strings.couldNotRun(itemTitle), message: Strings.notAnsweringMessage(appName))
        }
    }

    private var readAgainAction: Action {
        Action(Strings.readAgain, id: "read-again", icon: .symbol("arrow.clockwise"), shortcut: .refresh) {
            [weak self] context in
            self?.readAgain(context)
            return .keepOpen
        }
    }

    // MARK: - What the page says

    private func emptyState(for target: MenuTarget) -> EmptyState {
        switch target {
        case .app(let app):
            EmptyState(
                icon: .symbol("hourglass"), title: Strings.readingTitle, message: Strings.readingMessage(app.name))
        case .leftOut(let app):
            EmptyState(
                icon: .symbol("eye.slash"), title: Strings.leftOutTitle(app.name), message: Strings.leftOutMessage)
        case .none:
            EmptyState(icon: .symbol("menubar.rectangle"), title: Strings.noAppTitle, message: Strings.noAppMessage)
        }
    }

    private func emptyState(for failure: MenuReadError, app: MenuApp) -> EmptyState {
        switch failure {
        case .accessMissing:
            EmptyState(
                icon: .symbol("lock"), title: Strings.needsAccessTitle, message: Strings.needsAccessMessage,
                actions: [
                    Action(
                        Strings.grantAccess, id: "grant-access", icon: .symbol("lock.open"), requires: [.accessibility]
                    ) { [weak self] context in
                        self?.readAgain(context)
                        return .keepOpen
                    }
                ])
        case .appQuit, .appNotRunning:
            EmptyState(icon: .symbol("app.dashed"), title: Strings.appGoneTitle(app.name), message: Strings.appGoneHint)
        case .noMenuBar:
            EmptyState(
                icon: .symbol("menubar.rectangle"), title: Strings.noMenuBarTitle,
                message: Strings.noMenuBarMessage(app.name))
        case .notAnswering, .itemGone, .itemDisabled, .elementFailed:
            EmptyState(
                icon: .symbol("exclamationmark.triangle"), title: Strings.notAnsweringTitle(app.name),
                message: Strings.notAnsweringMessage(app.name), actions: [readAgainAction])
        }
    }

    private func emptyState(for snapshot: MenuSnapshot, query: String) -> EmptyState {
        let app = snapshot.app.name
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return EmptyState(
                icon: .symbol("magnifyingglass"), title: Strings.noMatchesTitle, message: Strings.noMatchesMessage(app))
        }
        let message = snapshot.items.isEmpty ? Strings.noItemsMessage(app) : Strings.allHiddenMessage(app)
        return EmptyState(
            icon: .symbol("filemenu.and.selection"), title: Strings.noItemsTitle, message: message,
            actions: [readAgainAction])
    }

    /// A banner when the list may be incomplete or out of date.
    private func notice(for snapshot: MenuSnapshot) -> Notice? {
        var sentences: [String] = []
        switch snapshot.ending {
        case .timedOut:
            let limit = limits.timeLimit.formatted(
                .units(allowed: [.seconds, .milliseconds], width: .wide).locale(context.clock.locale))
            sentences.append(Strings.timedOutMessage(snapshot.app.name, limit: limit))
        case .tooManyItems:
            sentences.append(
                Strings.tooManyMessage(limits.maximumItems.formatted(.number.locale(context.clock.locale))))
        case .complete, .stopped:
            break
        }
        if snapshot.leftOutDeepMenus { sentences.append(Strings.deepMenusMessage(limits.maximumDepth)) }
        if !sentences.isEmpty {
            return Notice(
                icon: .symbol("exclamationmark.triangle"), title: Strings.someMissingTitle,
                message: sentences.joined(separator: " "), action: readAgainAction)
        }
        if failure == .notAnswering {
            return Notice(
                icon: .symbol("exclamationmark.triangle"), title: Strings.outOfDateTitle,
                message: Strings.notAnsweringMessage(snapshot.app.name), action: readAgainAction)
        }
        return nil
    }
}

/// Tasks a page owns, cancelled together when it goes away. `Sendable`, so the page's deinit,
/// which is not on the main actor, can reach it.
nonisolated final class TaskBag: Sendable {
    private let tasks = Mutex<[Task<Void, Never>]>([])

    func add(_ task: Task<Void, Never>?) {
        guard let task else { return }
        tasks.withLock { tasks in
            tasks.removeAll { $0.isCancelled }
            tasks.append(task)
        }
    }

    func cancelAll() {
        for task in tasks.withLock({ $0 }) { task.cancel() }
    }
}
