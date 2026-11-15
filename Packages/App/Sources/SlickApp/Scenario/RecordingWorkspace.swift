import Foundation
import Kit
import Synchronization

/// The workspace a scenario gives the features: it records every launch, open and reveal and does
/// none of them, so a scenario can check that running an app reached the workspace. Trash is
/// refused, as in every isolated run. Everything else comes from the inert workspace it wraps.
nonisolated final class RecordingWorkspace: WorkspaceService {
    /// One request a feature made.
    enum Request: Hashable, Sendable {
        case launch(bundleID: String)
        case open(URL)
        case openWith(urls: [URL], bundleID: String)
        case reveal([URL])
    }

    private let base: any WorkspaceService
    private let log = Mutex<[Request]>([])

    init(wrapping base: any WorkspaceService) {
        self.base = base
    }

    /// Every request so far, oldest first.
    var requests: [Request] { log.withLock { $0 } }

    /// The bundle IDs launched so far, oldest first.
    var launchedBundleIDs: [String] {
        requests.compactMap { request in
            if case .launch(let bundleID) = request { return bundleID }
            return nil
        }
    }

    /// The URLs opened so far, oldest first.
    var openedURLs: [URL] {
        requests.compactMap { request in
            if case .open(let url) = request { return url }
            return nil
        }
    }

    func open(_ url: URL) async throws {
        log.withLock { $0.append(.open(url)) }
    }

    func open(_ urls: [URL], withApplication bundleID: String) async throws {
        log.withLock { $0.append(.openWith(urls: urls, bundleID: bundleID)) }
    }

    func reveal(_ urls: [URL]) async {
        log.withLock { $0.append(.reveal(urls)) }
    }

    @concurrent func moveToTrash(_ urls: [URL]) async throws -> [URL] {
        try await base.moveToTrash(urls)
    }

    @concurrent func applications(toOpen url: URL) async -> [AppInfo] {
        await base.applications(toOpen: url)
    }

    func application(bundleID: String) -> AppInfo? {
        base.application(bundleID: bundleID)
    }

    func frontmostApplication() -> AppInfo? {
        base.frontmostApplication()
    }

    func launch(bundleID: String) async throws {
        log.withLock { $0.append(.launch(bundleID: bundleID)) }
    }
}
