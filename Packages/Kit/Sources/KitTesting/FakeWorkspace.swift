import Foundation
import Kit
import Synchronization

/// A workspace that records what would have been opened, revealed, trashed or launched, and does
/// none of it.
public final class FakeWorkspace: WorkspaceService {
    /// One call to open URLs with a specific app.
    public struct OpenWith: Hashable, Sendable {
        public var urls: [URL]
        public var bundleID: String
    }

    private struct State {
        var opened: [URL] = []
        var openedWith: [OpenWith] = []
        var revealed: [URL] = []
        var trashed: [URL] = []
        var launched: [String] = []
        var applications: [AppInfo] = []
        var installed: [AppInfo] = []
        var frontmost: AppInfo?
        var failsToOpen = false
        var refusesToLaunch: Set<String> = []
    }

    private let state = Mutex(State())

    public init() {}

    public var opened: [URL] { state.withLock { $0.opened } }
    public var openedWith: [OpenWith] { state.withLock { $0.openedWith } }
    public var revealed: [URL] { state.withLock { $0.revealed } }
    public var trashed: [URL] { state.withLock { $0.trashed } }
    public var launched: [String] { state.withLock { $0.launched } }

    /// What ``applications(toOpen:)`` returns.
    public var applications: [AppInfo] {
        get { state.withLock { $0.applications } }
        set { state.withLock { $0.applications = newValue } }
    }

    /// The apps ``application(bundleID:)`` knows, besides ``applications`` and ``frontmost``.
    public var installed: [AppInfo] {
        get { state.withLock { $0.installed } }
        set { state.withLock { $0.installed = newValue } }
    }

    /// What ``frontmostApplication()`` returns.
    public var frontmost: AppInfo? {
        get { state.withLock { $0.frontmost } }
        set { state.withLock { $0.frontmost = newValue } }
    }

    /// When true, opening and trashing throw ``FakeWorkspaceError``.
    public var failsToOpen: Bool {
        get { state.withLock { $0.failsToOpen } }
        set { state.withLock { $0.failsToOpen = newValue } }
    }

    public func open(_ url: URL) async throws {
        try state.withLock { state in
            if state.failsToOpen { throw FakeWorkspaceError.refused }
            state.opened.append(url)
        }
    }

    public func open(_ urls: [URL], withApplication bundleID: String) async throws {
        try state.withLock { state in
            if state.failsToOpen { throw FakeWorkspaceError.refused }
            state.openedWith.append(OpenWith(urls: urls, bundleID: bundleID))
        }
    }

    public func reveal(_ urls: [URL]) async {
        state.withLock { $0.revealed += urls }
    }

    public func moveToTrash(_ urls: [URL]) async throws -> [URL] {
        try state.withLock { state in
            if state.failsToOpen { throw FakeWorkspaceError.refused }
            state.trashed += urls
        }
        return urls.map { URL(filePath: "/.Trash").appending(path: $0.lastPathComponent) }
    }

    public func applications(toOpen url: URL) async -> [AppInfo] {
        state.withLock { $0.applications }
    }

    public func application(bundleID: String) -> AppInfo? {
        state.withLock { state in
            (state.installed + state.applications + [state.frontmost].compactMap(\.self)).first {
                $0.bundleID == bundleID
            }
        }
    }

    public func frontmostApplication() -> AppInfo? {
        state.withLock { $0.frontmost }
    }

    /// The bundle IDs ``launch(bundleID:)`` refuses with ``FakeWorkspaceError``, as when the app
    /// is not installed. A refused launch is not recorded in ``launched``.
    public var refusesToLaunch: Set<String> {
        get { state.withLock { $0.refusesToLaunch } }
        set { state.withLock { $0.refusesToLaunch = newValue } }
    }

    public func launch(bundleID: String) async throws {
        try state.withLock { state in
            if state.refusesToLaunch.contains(bundleID) { throw FakeWorkspaceError.refused }
            state.launched.append(bundleID)
        }
    }
}

/// The error a ``FakeWorkspace`` throws when told to fail.
public enum FakeWorkspaceError: Error, Hashable, Sendable {
    case refused
}
