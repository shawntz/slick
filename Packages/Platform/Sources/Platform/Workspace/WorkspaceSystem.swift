import AppKit
import Foundation
import Kit

/// The calls into `NSWorkspace` and `FileManager` that ``LiveWorkspace`` makes, so its logic can be
/// tested with a fake that opens and launches nothing.
nonisolated public protocol WorkspaceSystem: Sendable {
    /// Opens a URL or file in its default app.
    func open(_ url: URL) async throws
    /// Opens URLs or files with the app at a location.
    func open(_ urls: [URL], withApplicationAt application: URL) async throws
    /// Selects files in Finder.
    func reveal(_ urls: [URL]) async
    /// Moves one item to the Trash and returns where it went. Blocks on the disk.
    func moveToTrash(_ url: URL) throws -> URL
    /// The apps that can open a URL, the default app first. May read the disk.
    func applicationURLs(toOpen url: URL) -> [URL]
    /// Where the app with this bundle ID is installed, from LaunchServices. May read the disk.
    func applicationURL(bundleID: String) -> URL?
    /// Launches the app at a location, or brings it forward when it runs.
    func openApplication(at url: URL) async throws
}

/// The real workspace.
nonisolated public struct NSWorkspaceSystem: WorkspaceSystem {
    public init() {}

    public func open(_ url: URL) async throws {
        _ = try await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
    }

    public func open(_ urls: [URL], withApplicationAt application: URL) async throws {
        _ = try await NSWorkspace.shared.open(
            urls, withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }

    public func reveal(_ urls: [URL]) async {
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    public func moveToTrash(_ url: URL) throws -> URL {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting.map { $0 as URL } ?? url
    }

    public func applicationURLs(toOpen url: URL) -> [URL] {
        let all = NSWorkspace.shared.urlsForApplications(toOpen: url)
        guard let preferred = NSWorkspace.shared.urlForApplication(toOpen: url) else { return all }
        return [preferred] + all.filter { $0.standardizedFileURL != preferred.standardizedFileURL }
    }

    public func applicationURL(bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    public func openApplication(at url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}

/// A workspace for run environments other than `live`: it opens, trashes and launches nothing and
/// knows no apps. Calls with a side effect throw ``PlatformServiceError/unavailable(_:)``; reveal
/// does nothing.
nonisolated public struct IsolatedWorkspaceSystem: WorkspaceSystem {
    public let environment: RunEnvironment

    public init(environment: RunEnvironment) {
        self.environment = environment
    }

    public func open(_ url: URL) async throws {
        throw PlatformServiceError.unavailable(environment)
    }

    public func open(_ urls: [URL], withApplicationAt application: URL) async throws {
        throw PlatformServiceError.unavailable(environment)
    }

    public func reveal(_ urls: [URL]) async {}

    public func moveToTrash(_ url: URL) throws -> URL {
        throw PlatformServiceError.unavailable(environment)
    }

    public func applicationURLs(toOpen url: URL) -> [URL] { [] }

    public func applicationURL(bundleID: String) -> URL? { nil }

    public func openApplication(at url: URL) async throws {
        throw PlatformServiceError.unavailable(environment)
    }
}
