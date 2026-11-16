import Foundation
import KitHosting
import Platform

/// A scenario's `"systemApps": true`: the Apps feature lists Apple's own apps from
/// `/System/Applications` with their real names and icons, so a clip can show real icons without
/// showing anything of the person who runs it.
///
/// What it reads, and nothing else:
/// - `/System/Applications` and its subfolders one level down, such as `Utilities`: the folder
///   listings, and each app's `Contents/Info.plist`.
/// - For names, each of those apps' `InfoPlist.loctable` or `en.lproj/InfoPlist.strings`, which
///   the Apps feature reads itself.
/// - For icons, Platform's live icon renderer draws each of those apps from its own location.
///
/// It never reads `/Applications`, `~/Applications` or anything in the home folder: the Apps
/// feature's scenario tree keeps its folder for other apps empty, and its tree of made-up apps is
/// not written.
nonisolated enum SystemApps {
    /// The only folder the scenario reads apps from.
    static let folder = URL(filePath: "/System/Applications", directoryHint: .isDirectory)
    /// How deep it reads: the folder and one level of subfolders.
    static let depth = 2

    /// The Apps feature's scenario tree in a data folder, as its isolated library finds it:
    /// `<data>/Caches/apps/synthetic-apps`.
    static func appsTree(in dataRoot: URL) -> URL {
        dataRoot.appending(path: "Caches/apps/synthetic-apps", directoryHint: .isDirectory)
    }

    /// Lays out the Apps feature's scenario tree so it lists the system's apps: the marker that
    /// says the tree is written, an empty folder for other apps, and its folder for system apps as
    /// a link to ``folder``. Call it before the features start. Deleting the data folder removes
    /// the link, never what it points at.
    static func prepare(dataRoot: URL) throws {
        let tree = appsTree(in: dataRoot)
        let manager = FileManager.default
        try manager.createDirectory(at: tree.appending(path: "Applications"), withIntermediateDirectories: true)
        try manager.createDirectory(at: tree.appending(path: "System"), withIntermediateDirectories: true)
        let link = tree.appending(path: "System/Applications")
        if (try? manager.destinationOfSymbolicLink(atPath: link.path)) == nil {
            try manager.createSymbolicLink(at: link, withDestinationURL: folder)
        }
        try Data("system".utf8).write(to: tree.appending(path: "tree-version"))
    }

    /// Every app in ``folder`` with its bundle ID, read from its own property list. Runs off the
    /// main thread's way: call it from a background task.
    static func entries(in folder: URL = folder, depth: Int = depth) -> [AppIconEntry] {
        var found: [AppIconEntry] = []
        collect(in: folder, depth: depth, into: &found)
        return found
    }

    private static func collect(in folder: URL, depth: Int, into found: inout [AppIconEntry]) {
        guard depth > 0,
            let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        else { return }
        for name in names.sorted() where !name.hasPrefix(".") {
            let url = folder.appending(path: name)
            if name.hasSuffix(".app") {
                if let bundleID = bundleID(of: url) {
                    found.append(AppIconEntry(bundleID: bundleID, url: url, stamp: url.path(percentEncoded: false)))
                }
            } else {
                var isFolder: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isFolder),
                    isFolder.boolValue
                {
                    collect(in: url, depth: depth - 1, into: &found)
                }
            }
        }
    }

    /// The bundle ID in an app's `Contents/Info.plist`, read as a file. Nothing asks
    /// LaunchServices.
    static func bundleID(of app: URL) -> String? {
        let plist = app.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty
        else { return nil }
        return bundleID
    }

    /// The icons a scenario with the system's apps draws: Platform's live renderer over the
    /// system's apps, with the run's own icon folders. The renderer may read only inside
    /// ``folder``: a file anywhere else, such as a scenario's made-up document, gets its type's
    /// generic icon, so no made-up file reaches LaunchServices. The run's HTTP service refuses
    /// every request, so nothing is downloaded.
    @MainActor static func icons(platform: PlatformServices) -> IconCache {
        let prefix = folder.path(percentEncoded: false)
        return IconCache(
            folders: platform.storage.iconFolders, renderer: LiveIconRenderer(),
            apps: StaticAppIcons(entries()), http: platform.http, settings: platform.settings,
            readGuard: ReadGuard { $0.standardizedFileURL.path(percentEncoded: false).hasPrefix(prefix) })
    }
}
