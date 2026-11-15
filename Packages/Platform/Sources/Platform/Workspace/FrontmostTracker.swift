import AppKit
import Foundation
import Kit
import Synchronization

/// The app that was frontmost before the panel opened, kept current from activation
/// notifications. It never records the app itself: while the panel is key, the app before it stays.
nonisolated public final class FrontmostTracker: Sendable {
    private let state: Mutex<Frontmost>
    private let changed = Broadcast<AppInfo?>()

    private struct Frontmost {
        var app: AppInfo?
        var processID: Int32?
    }
    /// The process to ignore: this app's.
    public let ownProcessID: Int32
    /// The bundle ID to ignore: this app's.
    public let ownBundleID: String?

    public init(
        ownProcessID: Int32 = ProcessInfo.processInfo.processIdentifier,
        ownBundleID: String? = Bundle.main.bundleIdentifier,
        initial: AppInfo? = nil
    ) {
        self.ownProcessID = ownProcessID
        self.ownBundleID = ownBundleID
        state = Mutex(Frontmost(app: initial))
    }

    /// The frontmost app other than this one, or nil before the first activation.
    public var current: AppInfo? {
        state.withLock { $0.app }
    }

    /// The process ID of ``current``, or nil before the first activation.
    public var currentProcessID: Int32? {
        state.withLock { $0.processID }
    }

    /// Records an app becoming frontmost. This app's own activations are ignored.
    public func activated(_ app: AppInfo, processID: Int32) {
        guard processID != ownProcessID, app.bundleID != ownBundleID else { return }
        let didChange = state.withLock { current -> Bool in
            defer { current = Frontmost(app: app, processID: processID) }
            return current.app != app
        }
        if didChange { changed.send(app) }
    }

    /// The frontmost app each time it changes from now on.
    public func changes() -> AsyncStream<AppInfo?> {
        changed.stream()
    }

    /// A signal each time another app comes forward, from now on.
    public func activations() -> AsyncStream<Void> {
        changed.stream { _ in () }
    }

    /// How many streams are open. For tests.
    var listenerCount: Int {
        changed.listenerCount
    }
}

/// Feeds a ``FrontmostTracker`` and an ``ApplicationCatalog`` from `NSWorkspace`: the frontmost app
/// at start, every activation after, and the running apps. Only reads; never activates anything.
@MainActor public final class WorkspaceObserver {
    private let tracker: FrontmostTracker
    private let catalog: ApplicationCatalog
    private let notifications: NotificationCenter
    private let runningApplications: @MainActor () -> [NSRunningApplication]
    private let frontmostApplication: @MainActor () -> NSRunningApplication?
    private let info: @Sendable (NSRunningApplication) -> AppInfo?
    private var observer: (any NSObjectProtocol)?

    /// - Parameters:
    ///   - notifications: Where activations are posted. Tests pass a private center.
    ///   - runningApplications: The apps running at start.
    ///   - frontmostApplication: The app in front at start.
    ///   - info: What the tracker records for an app.
    public init(
        tracker: FrontmostTracker, catalog: ApplicationCatalog,
        notifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
        runningApplications: @escaping @MainActor () -> [NSRunningApplication] = {
            NSWorkspace.shared.runningApplications
        },
        frontmostApplication: @escaping @MainActor () -> NSRunningApplication? = {
            NSWorkspace.shared.frontmostApplication
        },
        info: @escaping @Sendable (NSRunningApplication) -> AppInfo? = WorkspaceObserver.info
    ) {
        self.tracker = tracker
        self.catalog = catalog
        self.notifications = notifications
        self.runningApplications = runningApplications
        self.frontmostApplication = frontmostApplication
        self.info = info
    }

    /// Removes the observer when the object goes away without ``stop()``. Found in review: the
    /// notification center kept the observer, and with it the tracker and catalog, for good.
    isolated deinit {
        stop()
    }

    /// Starts listening. Calling it again does nothing.
    public func start() {
        guard observer == nil else { return }
        let info = info
        catalog.insert(runningApplications().compactMap(info))
        if let app = frontmostApplication(), let found = info(app) {
            tracker.activated(found, processID: app.processIdentifier)
        }
        observer = notifications.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [tracker, catalog] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                let found = info(app)
            else { return }
            catalog.insert([found])
            tracker.activated(found, processID: app.processIdentifier)
        }
    }

    /// Stops listening.
    public func stop() {
        if let observer { notifications.removeObserver(observer) }
        observer = nil
    }

    /// The app as the tracker records it, or nil when it has no bundle ID.
    nonisolated public static func info(_ app: NSRunningApplication) -> AppInfo? {
        guard let bundleID = app.bundleIdentifier else { return nil }
        return AppInfo(bundleID: bundleID, name: app.localizedName ?? bundleID, url: app.bundleURL)
    }
}
