import Foundation
import Kit

/// The live workspace service: the rules on top of a ``WorkspaceSystem``.
///
/// ``application(bundleID:)`` and ``frontmostApplication()`` answer from memory, through the
/// ``ApplicationCatalog`` and the ``FrontmostTracker``. Everything that may read the disk runs off
/// the main thread.
nonisolated public final class LiveWorkspace: WorkspaceService {
    private let system: any WorkspaceSystem
    public let catalog: ApplicationCatalog
    public let frontmost: FrontmostTracker

    public init(system: any WorkspaceSystem, catalog: ApplicationCatalog, frontmost: FrontmostTracker) {
        self.system = system
        self.catalog = catalog
        self.frontmost = frontmost
    }

    public func open(_ url: URL) async throws {
        try await system.open(url)
    }

    public func open(_ urls: [URL], withApplication bundleID: String) async throws {
        guard !urls.isEmpty else { return }
        let application = try await locate(bundleID)
        try await system.open(urls, withApplicationAt: application)
    }

    public func reveal(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        await system.reveal(urls)
    }

    @concurrent public func moveToTrash(_ urls: [URL]) async throws -> [URL] {
        var moved: [URL] = []
        var failed: [URL] = []
        for url in urls {
            do {
                moved.append(try system.moveToTrash(url))
            } catch {
                failed.append(url)
            }
        }
        if !failed.isEmpty { throw WorkspaceError.trashFailed(failed, moved: moved) }
        return moved
    }

    @concurrent public func applications(toOpen url: URL) async -> [AppInfo] {
        var seen = Set<String>()
        var apps: [AppInfo] = []
        for location in system.applicationURLs(toOpen: url) {
            guard let app = ApplicationCatalog.application(at: location), seen.insert(app.bundleID).inserted else {
                continue
            }
            apps.append(app)
        }
        return apps
    }

    public func application(bundleID: String) -> AppInfo? {
        catalog.application(bundleID: bundleID)
    }

    public func frontmostApplication() -> AppInfo? {
        frontmost.current
    }

    public func launch(bundleID: String) async throws {
        let application = try await locate(bundleID)
        try await system.openApplication(at: application)
    }

    /// The app's location: the catalog's when it knows the app, else LaunchServices', off the
    /// main thread.
    @concurrent private func locate(_ bundleID: String) async throws -> URL {
        if let url = catalog.application(bundleID: bundleID)?.url { return url }
        guard let url = system.applicationURL(bundleID: bundleID) else {
            throw WorkspaceError.applicationNotFound(bundleID)
        }
        return url
    }
}

/// Why a workspace call failed.
nonisolated public enum WorkspaceError: Error, Hashable, Sendable, LocalizedError {
    /// No installed app has this bundle ID.
    case applicationNotFound(String)
    /// These items could not be moved to the Trash. The others moved to `moved`.
    case trashFailed([URL], moved: [URL])

    /// A title, as a failure toast shows it.
    public var errorDescription: String? {
        switch self {
        case .applicationNotFound: "App Not Installed"
        case .trashFailed: "Could Not Move to the Trash"
        }
    }

    /// What happened, as a sentence under the title.
    public var failureReason: String? {
        switch self {
        case .applicationNotFound(let bundleID): "No app with the identifier \(bundleID) is installed."
        case .trashFailed(let failed, _):
            failed.count == 1
                ? "\(DisplayText.fileName(failed[0].lastPathComponent)) could not be moved to the Trash."
                : "\(failed.count) items could not be moved to the Trash."
        }
    }
}
