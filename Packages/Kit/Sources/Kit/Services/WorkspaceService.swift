import Foundation

/// Opening, revealing and trashing files and URLs, and the apps that can handle them.
public protocol WorkspaceService: Sendable {
    /// Opens a URL or a file in its default app.
    func open(_ url: URL) async throws

    /// Opens files or URLs with a specific app.
    func open(_ urls: [URL], withApplication bundleID: String) async throws

    /// Selects the files in Finder.
    func reveal(_ urls: [URL]) async

    /// Moves files to the Trash and returns where they went. Throws if any could not be moved.
    @concurrent func moveToTrash(_ urls: [URL]) async throws -> [URL]

    /// The apps that can open a URL or file, the default app first.
    @concurrent func applications(toOpen url: URL) async -> [AppInfo]

    /// The installed app with this bundle ID, for its name, or nil. Cheap: the live service answers
    /// from a cache it keeps current, never from the disk.
    func application(bundleID: String) -> AppInfo?

    /// The app that was frontmost before the panel opened. Cheap; never blocks.
    func frontmostApplication() -> AppInfo?

    /// Launches an app, or brings it forward if it is running.
    func launch(bundleID: String) async throws
}

/// An application, as the workspace reports it.
public struct AppInfo: Hashable, Sendable, Codable {
    public var bundleID: String
    public var name: String
    /// The app's location, when known.
    public var url: URL?

    public init(bundleID: String, name: String, url: URL? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.url = url
    }
}
