import AppKit
import Foundation
import Kit
import KitTesting
import Synchronization
import Testing

@testable import Platform

/// The workspace runs over ``FakeWorkspaceSystem``: nothing opens, launches or moves. App bundles
/// are synthetic folders in a temporary directory.
@Suite(.timeLimit(.minutes(1))) struct WorkspaceTests {
    let system = FakeWorkspaceSystem()
    let tracker = FrontmostTracker(ownProcessID: 4242, ownBundleID: "com.example.self")

    func makeWorkspace(catalog: ApplicationCatalog = ApplicationCatalog(folders: [])) -> LiveWorkspace {
        LiveWorkspace(system: system, catalog: catalog, frontmost: tracker)
    }

    @Test func openRevealAndTrashGoThroughTheSystem() async throws {
        let workspace = makeWorkspace()
        let page = URL(string: "https://example.com/page")!
        try await workspace.open(page)
        await workspace.reveal([])
        await workspace.reveal([URL(filePath: "/synthetic/a.txt")])
        let moved = try await workspace.moveToTrash([
            URL(filePath: "/synthetic/a.txt"), URL(filePath: "/synthetic/b.txt"),
        ])
        #expect(moved.map(\.lastPathComponent) == ["a.txt", "b.txt"])
        system.state.withLock { state in
            #expect(state.opened == [page])
            #expect(state.revealed == [URL(filePath: "/synthetic/a.txt")])
            #expect(state.trashed.count == 2)
        }
    }

    @Test func aPartialTrashThrowsAndSaysWhatMoved() async {
        let workspace = makeWorkspace()
        let stuck = URL(filePath: "/synthetic/locked.txt")
        system.state.withLock { _ = $0.refusesToTrash.insert(stuck) }
        await #expect {
            try await workspace.moveToTrash([URL(filePath: "/synthetic/free.txt"), stuck])
        } throws: { error in
            guard case WorkspaceError.trashFailed(let failed, let moved) = error else { return false }
            return failed == [stuck] && moved.map(\.lastPathComponent) == ["free.txt"]
        }
    }

    @Test func openWithAndLaunchFindTheAppByBundleID() async throws {
        let folder = TemporaryFolder()
        let editor = try folder.makeApp("Editor.app", info: ["CFBundleIdentifier": "com.example.editor"])
        let catalog = ApplicationCatalog(folders: [folder.url])
        await catalog.refresh()
        let workspace = makeWorkspace(catalog: catalog)
        let file = URL(filePath: "/synthetic/notes.txt")

        try await workspace.open([file], withApplication: "com.example.editor")
        try await workspace.launch(bundleID: "com.example.editor")
        system.state.withLock { state in
            #expect(state.openedWith.first?.urls == [file])
            #expect(state.openedWith.first.map { canonicalPath($0.application) } == canonicalPath(editor))
            #expect(state.launched.map(canonicalPath) == [canonicalPath(editor)])
            #expect(state.lookups.isEmpty)  // the catalog knew it
        }

        // An app the catalog does not know is asked of LaunchServices.
        system.state.withLock { $0.installed["com.example.viewer"] = URL(filePath: "/synthetic/Viewer.app") }
        try await workspace.launch(bundleID: "com.example.viewer")
        await #expect(throws: WorkspaceError.applicationNotFound("com.example.missing")) {
            try await workspace.launch(bundleID: "com.example.missing")
        }
        #expect(system.state.withLock { $0.launched.last } == URL(filePath: "/synthetic/Viewer.app"))
    }

    @Test func appsThatCanOpenAURLComeFromTheirBundles() async throws {
        let folder = TemporaryFolder()
        let first = try folder.makeApp("First.app", info: ["CFBundleIdentifier": "com.example.first"])
        let second = try folder.makeApp(
            "Second.app", info: ["CFBundleIdentifier": "com.example.second", "CFBundleDisplayName": "Second Viewer"])
        system.state.withLock { $0.handlers = [first, second, first] }
        let apps = await makeWorkspace().applications(toOpen: URL(filePath: "/synthetic/photo.png"))
        #expect(apps.map(\.bundleID) == ["com.example.first", "com.example.second"])
        #expect(apps.map(\.name) == ["First", "Second Viewer"])
    }

    @Test func theCatalogScansNamesAndAnswersFromMemory() async throws {
        let folder = TemporaryFolder()
        try folder.makeApp("Plain.app", info: ["CFBundleIdentifier": "com.example.plain"])
        try folder.makeApp(
            "Named.app", info: ["CFBundleIdentifier": "com.example.named", "CFBundleName": "Bundle Name"])
        try folder.makeApp(
            "Shown.app",
            info: [
                "CFBundleIdentifier": "com.example.shown", "CFBundleName": "Inner", "CFBundleDisplayName": "Shown Name",
            ])
        try folder.makeApp("Suite/Nested.app", info: ["CFBundleIdentifier": "com.example.nested"])
        try folder.makeApp("Deep/Deeper/TooDeep.app", info: ["CFBundleIdentifier": "com.example.toodeep"])
        try folder.makeApp("NoID.app", info: ["CFBundleName": "No Identifier"])

        let located = Counter()
        let catalog = ApplicationCatalog(folders: [folder.url]) { bundleID in
            located.increment()
            return bundleID == "com.example.late" ? URL(filePath: "/synthetic/missing.app") : nil
        }
        #expect(catalog.application(bundleID: "com.example.plain") == nil)
        await catalog.refresh()
        #expect(catalog.application(bundleID: "com.example.plain")?.name == "Plain")
        #expect(catalog.application(bundleID: "com.example.named")?.name == "Bundle Name")
        #expect(catalog.application(bundleID: "com.example.shown")?.name == "Shown Name")
        #expect(catalog.application(bundleID: "com.example.nested")?.name == "Nested")
        #expect(catalog.applications.count == 4)
        #expect(catalog.scanCount == 1)

        // A miss asks LaunchServices once, in the background.
        #expect(catalog.application(bundleID: "com.example.toodeep") == nil)
        #expect(catalog.application(bundleID: "com.example.toodeep") == nil)
        try await waitUntil { located.value == 2 }  // the first miss before the scan, and this one
        try await Task.sleep(for: .milliseconds(50))
        #expect(located.value == 2)

        catalog.insert([AppInfo(bundleID: "com.example.running", name: "Running")])
        #expect(catalog.application(bundleID: "com.example.running")?.name == "Running")
        withExtendedLifetime(folder) {}
    }

    @Test func theCatalogRescansWhenItsFoldersChange() async throws {
        let folder = TemporaryFolder()
        let watcher = FakeFileWatcher()
        let catalog = ApplicationCatalog(folders: [folder.url])
        let refreshing = catalog.refreshing(on: watcher)
        defer { refreshing.cancel() }
        try await waitUntil { catalog.scanCount == 1 }
        try folder.makeApp("Added.app", info: ["CFBundleIdentifier": "com.example.added"])
        watcher.simulateChange([folder.url.appending(path: "Added.app")])
        try await waitUntil { catalog.scanCount == 2 }
        #expect(catalog.application(bundleID: "com.example.added") != nil)
        withExtendedLifetime(folder) {}
    }

    /// Found in review: every batch of FSEvents rescanned, so an app update meant a scan every
    /// 200 ms. A burst now leads to at most two scans.
    @Test func aBurstOfFolderChangesRescansOnceOrTwice() async throws {
        let folder = TemporaryFolder()
        let watcher = FakeFileWatcher()
        let catalog = ApplicationCatalog(folders: [folder.url])
        let refreshing = catalog.refreshing(on: watcher, quietPeriod: .milliseconds(50))
        defer { refreshing.cancel() }
        try await waitUntil { catalog.scanCount == 1 }
        for _ in 0..<20 {
            watcher.simulateChange([folder.url])
        }
        try await waitUntil { catalog.scanCount >= 2 }
        try await Task.sleep(for: .milliseconds(250))
        #expect(catalog.scanCount <= 3)
        refreshing.cancel()
        await refreshing.value
        withExtendedLifetime(folder) {}
    }

    /// Found in review: an observer dropped without stop() stayed registered for good.
    @Test func aWorkspaceObserverDroppedWithoutStopStopsListening() async {
        let notifications = NotificationCenter()
        let tracker = FrontmostTracker(ownProcessID: 4242, ownBundleID: "com.example.self")
        let catalog = ApplicationCatalog(folders: [])
        let synthetic = Locked(AppInfo(bundleID: "com.example.first", name: "First"))
        var observer: WorkspaceObserver? = WorkspaceObserver(
            tracker: tracker, catalog: catalog, notifications: notifications, runningApplications: { [] },
            frontmostApplication: { nil }, info: { _ in synthetic.value })
        observer?.start()
        let activation = { () in
            notifications.post(
                name: NSWorkspace.didActivateApplicationNotification, object: nil,
                userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        }
        activation()
        #expect(tracker.current?.bundleID == "com.example.first")
        #expect(catalog.application(bundleID: "com.example.first") != nil)

        observer = nil
        synthetic.value = AppInfo(bundleID: "com.example.second", name: "Second")
        activation()
        #expect(tracker.current?.bundleID == "com.example.first")
        withExtendedLifetime(observer) {}
    }

    @Test func theFrontmostAppIsNeverThisApp() async {
        let workspace = makeWorkspace()
        var changes = tracker.changes().makeAsyncIterator()
        let editor = AppInfo(bundleID: "com.example.editor", name: "Editor")
        tracker.activated(editor, processID: 100)
        tracker.activated(AppInfo(bundleID: "com.example.self", name: "Self"), processID: 101)
        tracker.activated(AppInfo(bundleID: "com.example.other", name: "Same process"), processID: 4242)
        tracker.activated(editor, processID: 100)
        #expect(workspace.frontmostApplication() == editor)
        let browser = AppInfo(bundleID: "com.example.browser", name: "Browser")
        tracker.activated(browser, processID: 102)
        #expect(await changes.next() == editor)
        #expect(await changes.next() == browser)
    }

    @Test func outsideLiveNothingOpens() async {
        let isolated = LiveWorkspace(
            system: IsolatedWorkspaceSystem(environment: .scenario), catalog: ApplicationCatalog(folders: []),
            frontmost: tracker)
        await #expect(throws: PlatformServiceError.unavailable(.scenario)) {
            try await isolated.open(URL(string: "https://example.com")!)
        }
        await #expect(throws: WorkspaceError.trashFailed([URL(filePath: "/x")], moved: [])) {
            try await isolated.moveToTrash([URL(filePath: "/x")])
        }
        await #expect(throws: WorkspaceError.self) { try await isolated.launch(bundleID: "com.example.editor") }
        #expect(await isolated.applications(toOpen: URL(filePath: "/x")).isEmpty)
    }
}

/// A thread-safe counter for callbacks.
nonisolated final class Counter: Sendable {
    private let count = Mutex(0)

    func increment() {
        count.withLock { $0 += 1 }
    }

    var value: Int { count.withLock { $0 } }
}
