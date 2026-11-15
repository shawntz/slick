import Foundation
import Kit
import Synchronization

/// Installed apps by bundle ID, kept in memory so ``application(bundleID:)`` never reads the disk.
///
/// ``refresh()`` scans the app folders off the main thread, two levels deep, reading each app's
/// `Info.plist`. Scanning about 270 apps takes under a millisecond of disk work, so every change
/// rescans everything. Apps seen running are added as they activate. A lookup that misses asks
/// LaunchServices once, on a background queue, and the next lookup finds the answer.
///
/// Names come from `CFBundleDisplayName`, then `CFBundleName`, then the file name. They are not
/// localized.
nonisolated public final class ApplicationCatalog: Sendable {
    private struct State {
        var scanned: [String: AppInfo] = [:]
        /// Apps learned from running apps and LaunchServices lookups, kept across scans.
        var learned: [String: AppInfo] = [:]
        /// Bundle IDs already looked up since the last scan.
        var looked: Set<String> = []
        var scans = 0
    }

    /// The folders a scan reads.
    public let folders: [URL]
    private let locate: @Sendable (String) -> URL?
    private let state = Mutex(State())
    /// Sent after a scan or a lookup added apps.
    public let changes = ChangeSignal()

    /// - Parameters:
    ///   - folders: The folders to scan, such as ``standardFolders(home:)``.
    ///   - locate: Finds an app's location by bundle ID when a lookup misses, such as
    ///     `WorkspaceSystem.applicationURL(bundleID:)`. Called on a background queue.
    public init(folders: [URL], locate: @escaping @Sendable (String) -> URL? = { _ in nil }) {
        self.folders = folders
        self.locate = locate
    }

    /// The usual app folders: `/Applications`, `/System/Applications`, the Core Services apps and
    /// the user's own `Applications` folder.
    public static func standardFolders(home: URL) -> [URL] {
        [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            URL(filePath: "/System/Applications", directoryHint: .isDirectory),
            URL(filePath: "/System/Library/CoreServices/Applications", directoryHint: .isDirectory),
            home.appending(path: "Applications", directoryHint: .isDirectory),
        ]
    }

    /// The app with this bundle ID, from memory. On a miss it asks LaunchServices in the background
    /// once, so a later call may find it.
    public func application(bundleID: String) -> AppInfo? {
        let (found, shouldLook) = state.withLock { state -> (AppInfo?, Bool) in
            if let app = state.scanned[bundleID] ?? state.learned[bundleID] { return (app, false) }
            return (nil, state.looked.insert(bundleID).inserted)
        }
        if shouldLook { lookUp(bundleID) }
        return found
    }

    /// Adds apps seen running.
    public func insert(_ apps: [AppInfo]) {
        state.withLock { state in
            for app in apps where state.scanned[app.bundleID] == nil {
                state.learned[app.bundleID] = app
            }
        }
    }

    /// Every app known now, by bundle ID.
    public var applications: [String: AppInfo] {
        state.withLock { $0.learned.merging($0.scanned) { _, scanned in scanned } }
    }

    /// How many scans have finished.
    public var scanCount: Int {
        state.withLock { $0.scans }
    }

    /// Scans the folders again and replaces what earlier scans found.
    @concurrent public func refresh() async {
        let found = Self.scan(folders)
        state.withLock { state in
            state.scanned = found
            state.looked = []
            state.scans += 1
        }
        changes.send()
    }

    /// Scans now, then again after things change in the folders, until the task is cancelled. A
    /// burst of changes, such as an app being copied or updated, waits for `quietPeriod` and
    /// leads to one or two scans, not one per batch of events.
    public func refreshing(
        on watcher: any FileWatchService, quietPeriod: Duration = .milliseconds(500)
    ) -> Task<Void, Never> {
        let changes = watcher.watch(folders)
        let pending = ChangeSignal()
        let ticks = pending.stream()
        return Task.detached(priority: .utility) { [self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in changes {
                        pending.send()
                    }
                }
                group.addTask { [self] in
                    await refresh()
                    for await _ in ticks {
                        try? await Task.sleep(for: quietPeriod)
                        guard !Task.isCancelled else { return }
                        await refresh()
                    }
                }
            }
        }
    }

    private func lookUp(_ bundleID: String) {
        let locate = locate
        DispatchQueue.global(qos: .utility).async { [self] in
            guard let url = locate(bundleID), let app = Self.application(at: url), app.bundleID == bundleID else {
                return
            }
            insert([app])
            changes.send()
        }
    }

    /// Every app in the folders, two levels deep. The first folder that holds a bundle ID wins.
    static func scan(_ folders: [URL]) -> [String: AppInfo] {
        var found: [String: AppInfo] = [:]
        func visit(_ folder: URL, depth: Int) {
            let entries =
                (try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if entry.pathExtension == "app" {
                    if let app = application(at: entry), found[app.bundleID] == nil { found[app.bundleID] = app }
                } else if depth < 1, (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    visit(entry, depth: depth + 1)
                }
            }
        }
        for folder in folders {
            visit(folder, depth: 0)
        }
        return found
    }

    /// The app at a bundle location, from its `Info.plist`, or nil when it has no bundle ID.
    static func application(at url: URL) -> AppInfo? {
        let plist = url.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: plist),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty
        else { return nil }
        let fileName = url.deletingPathExtension().lastPathComponent
        let name = [info["CFBundleDisplayName"], info["CFBundleName"]]
            .compactMap { $0 as? String }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return AppInfo(bundleID: bundleID, name: name ?? fileName, url: url)
    }
}
