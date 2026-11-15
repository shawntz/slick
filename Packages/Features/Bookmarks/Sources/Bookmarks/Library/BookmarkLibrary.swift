import Foundation
import Kit
import os

/// The bookmarks the feature shows, kept current.
///
/// It reads only the browsers the user switched on, and Safari only while the feature holds Full
/// Disk Access. Loads run one at a time in ``BookmarkLoader``, off the main thread; the main thread
/// only swaps in the finished snapshot. While it runs it follows three things:
///
/// - the settings that choose browsers, to read again when they change;
/// - the browsers' folders through Kit's file watcher, to read again when a bookmarks file changes;
/// - Full Disk Access, only while Safari is chosen and the access is missing, to read Safari as
///   soon as the user grants it.
final class BookmarkLibrary {
    /// Sent after the bookmarks or the problems changed.
    let changes = ChangeSignal()
    /// Called when what settings shows about the feature may have changed.
    var onStatusChange: (() -> Void)?

    private(set) var snapshot = BookmarkSnapshot.empty
    private(set) var problems: [SourceProblem] = []

    private let context: FeatureContext
    private let files: any BookmarkFileService
    private let loader: BookmarkLoader
    private var loading: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    /// Counts queued loads, so a load that a newer one covers is skipped.
    private var queued = 0
    private var wantsForce = false
    /// Whether the last load could include Safari, so a change in access is noticed.
    private var loadedWithSafariAccess: Bool?
    private var settingsWatch: Task<Void, Never>?
    private var fileWatch: Task<Void, Never>?
    private var accessWatch: Task<Void, Never>?
    private var watchedFolders: [URL] = []
    private var isActive = false

    init(context: FeatureContext, files: any BookmarkFileService) {
        self.context = context
        self.files = files
        loader = BookmarkLoader(files: files, clock: context.clock)
    }

    // MARK: - What the user chose

    var chosenBrowsers: [Browser] { BookmarkSettings.chosenBrowsers(context.settings) }

    var hasFullDiskAccess: Bool { context.permissions.isGranted(.fullDiskAccess) }

    /// True when Safari is chosen and cannot be read for lack of Full Disk Access.
    var safariNeedsAccess: Bool { chosenBrowsers.contains(.safari) && !hasFullDiskAccess }

    /// The browsers a load may read: the chosen ones, Safari only with access.
    var readableBrowsers: [Browser] {
        let access = hasFullDiskAccess
        return chosenBrowsers.filter { !$0.needsFullDiskAccess || access }
    }

    // MARK: - Running

    /// Starts following the settings that choose browsers. Reads nothing: the first read waits for
    /// something the user does, such as opening Search Bookmarks, choosing a browser, or root search
    /// asking for bookmarks after the user turned that on. Returns at once.
    func start() {
        guard !isActive else { return }
        isActive = true
        let settingChanges = context.settings.changes(ofAny: BookmarkSettings.sourceKeys)
        settingsWatch = Task { [weak self] in
            for await _ in settingChanges { await self?.settingsChanged() }
        }
    }

    /// Stops every watch and load and lets the bookmarks go.
    func stop() {
        isActive = false
        for task in [settingsWatch, fileWatch, accessWatch, loading, retry] { task?.cancel() }
        settingsWatch = nil
        fileWatch = nil
        accessWatch = nil
        loading = nil
        retry = nil
        watchedFolders = []
        loadedWithSafariAccess = nil
        snapshot = .empty
        problems = []
        let loader = loader
        Task { await loader.reset() }
    }

    /// Loads again, after any load already running. The settings are read when the load starts, so
    /// it always reads what the user chose last. With `force`, every file is read even when its
    /// stamp did not change.
    @discardableResult
    func reload(force: Bool = false) -> Task<Void, Never> {
        if force { wantsForce = true }
        queued += 1
        let ticket = queued
        let previous = loading
        let task = Task { [weak self] in
            await previous?.value
            guard let self, self.isActive, ticket == self.queued, !Task.isCancelled else { return }
            await self.load()
        }
        loading = task
        return task
    }

    /// Returns once the bookmarks are as current as the settings and access allow: it starts a load
    /// if none ran yet or if Full Disk Access changed since the last one, and waits for it.
    func ready() async {
        guard isActive else { return }
        let access = chosenBrowsers.contains(.safari) ? hasFullDiskAccess : nil
        let accessChanged = access != nil && access != loadedWithSafariAccess
        if loading == nil && !chosenBrowsers.isEmpty || accessChanged {
            reload()
            watch()
            // Settings shows a status while Safari waits for access; it may have changed.
            if accessChanged { onStatusChange?() }
        }
        await loading?.value
    }

    private func load() async {
        let request = LoadRequest(
            browsers: readableBrowsers, includesReadingList: context.settings[BookmarkSettings.includesReadingList],
            force: wantsForce)
        wantsForce = false
        let access = chosenBrowsers.contains(.safari) ? hasFullDiskAccess : nil
        guard let result = await loader.load(request), isActive, !Task.isCancelled else { return }
        loadedWithSafariAccess = access
        let problemsChanged = result.problems != problems
        problems = result.problems
        if let snapshot = result.snapshot {
            self.snapshot = snapshot
            context.log.info(
                "Loaded \(snapshot.bookmarks.count) bookmarks from \(snapshot.profiles.count) profiles")
        }
        if result.snapshot != nil || problemsChanged { changes.send() }
        if problemsChanged { onStatusChange?() }
        if let delay = result.retryAfter { scheduleRetry(after: delay) }
    }

    private func scheduleRetry(after delay: Duration) {
        guard retry == nil else { return }
        let clock = context.clock
        retry = Task { [weak self] in
            try? await clock.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.retry = nil
            await self.reload().value
        }
    }

    private func settingsChanged() async {
        let task = reload()
        watch()
        onStatusChange?()
        await task.value
    }

    // MARK: - Watching

    /// Watches the folders of the browsers a load may read, and Full Disk Access while Safari waits
    /// for it. Replaces a watch whose folders changed.
    private func watch() {
        guard isActive else { return }
        let folders = readableBrowsers.map(files.watchFolder(for:))
        if folders != watchedFolders {
            fileWatch?.cancel()
            fileWatch = nil
            watchedFolders = folders
            if !folders.isEmpty {
                let events = context.fileWatcher.watch(folders)
                fileWatch = Task { [weak self] in
                    for await paths in events where paths.contains(where: Self.isBookmarkFile) {
                        await self?.reload().value
                    }
                }
            }
        }
        if safariNeedsAccess {
            watchAccess()
        } else {
            accessWatch?.cancel()
            accessWatch = nil
        }
    }

    /// While Safari waits for Full Disk Access, waits for the user to grant it in System Settings,
    /// then reads Safari. The live stream checks once a second, so it is open only while needed.
    private func watchAccess() {
        guard accessWatch == nil else { return }
        let statuses = context.permissions.changes(of: .fullDiskAccess)
        accessWatch = Task { [weak self] in
            for await status in statuses where status.isGranted {
                guard let self else { return }
                self.accessWatch = nil
                self.onStatusChange?()
                let task = self.reload()
                self.watch()
                await task.value
                // Ending by cancellation, not by leaving the loop, tells the stream it is done.
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
    }

    /// True for a path whose change may mean a bookmark changed.
    nonisolated static func isBookmarkFile(_ path: URL) -> Bool {
        BrowserFolders.watchedNames.contains(path.lastPathComponent)
    }

    /// True while a Full Disk Access stream is open, for tests.
    var isWatchingAccess: Bool { accessWatch != nil }
}
