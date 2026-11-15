import Foundation

/// Finds the applications in a set of folders. Synchronous and file-bound: call it only from a
/// `@concurrent` function.
///
/// The rules come from the lab's measurements on macOS 27.2:
/// - Read folders with `readdir`, skip names that start with a dot, and treat every `.app` as a leaf.
///   Apps nest helpers inside themselves; those are not apps people open.
/// - Follow symlinks. `/Applications/Safari.app` is a symlink into the system's cryptex, and a scan
///   that ignores links loses Safari. Two paths to one bundle count once.
/// - Rescan everything on any change. The whole scan of 268 apps took 0.6 ms, so patching the
///   previous result would add code for nothing.
nonisolated struct AppScanner {
    var reader: BundleReader

    /// Folder extensions that are bundles but not apps. The scan never reads inside them.
    private static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "kext", "plugin", "prefpane", "qlgenerator", "xpc",
    ]

    /// Every app in the roots, in root order, then by file name inside each folder.
    func scan(_ roots: [AppScanRoot]) -> [InstalledApp] {
        var walk = Walk(reader: reader)
        for root in roots {
            walk.visit(folder: root.folder.path, depth: root.depth, root: root)
        }
        return Self.assignKeys(walk.found)
    }

    /// Gives each app its row key. The first copy of a bundle ID keeps the bare ID; a later copy,
    /// such as a beta next to the release, gets the ID and its path, and its file name as its title
    /// so the two rows read differently.
    static func assignKeys(_ apps: [InstalledApp]) -> [InstalledApp] {
        var seenIDs = Set<String>()
        return apps.map { app in
            var app = app
            guard let bundleID = app.bundleID else {
                app.key = app.path
                return app
            }
            if seenIDs.insert(bundleID).inserted {
                app.key = bundleID
            } else {
                app.key = bundleID + "@" + app.path
                let fileName = Self.fileName(of: app.path)
                if fileName != app.name {
                    app.keywords = [app.name] + app.keywords.filter { $0 != fileName }
                    app.name = fileName
                }
            }
            return app
        }
    }

    /// The last path component without ".app".
    static func fileName(of path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init) ?? path
        return last.lowercased().hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    /// One scan's state: what was found and which real paths were seen.
    private struct Walk {
        let reader: BundleReader
        var found: [InstalledApp] = []
        var seenBundles = Set<String>()
        var seenFolders = Set<String>()

        mutating func visit(folder: String, depth: Int, root: AppScanRoot) {
            // A symlink loop, or two roots that overlap, would read a folder twice.
            guard depth > 0, seenFolders.insert(Self.realPath(folder) ?? folder).inserted else { return }
            // By name without the extension, so "Xcode.app" comes before "Xcode-beta.app" and keeps
            // the bare bundle ID: a plain sort puts "-" and " " before ".".
            let entries = DirectoryEntries(folder).filter { !$0.name.hasPrefix(".") }.map { entry in
                (entry: entry, base: (entry.name as NSString).deletingPathExtension)
            }
            .sorted { ($0.base, $0.entry.name) < ($1.base, $1.entry.name) }.map(\.entry)
            for entry in entries {
                let path = folder + "/" + entry.name
                let pathExtension = (entry.name as NSString).pathExtension.lowercased()
                if pathExtension == "app" {
                    if root.only?.contains(entry.name) ?? true, Self.isFolder(path, type: entry.type) {
                        addApp(at: path, root: root)
                    }
                } else if root.only == nil, depth > 1, !AppScanner.packageExtensions.contains(pathExtension),
                    Self.isFolder(path, type: entry.type)
                {
                    visit(folder: path, depth: depth - 1, root: root)
                }
            }
        }

        private mutating func addApp(at path: String, root: AppScanRoot) {
            guard seenBundles.insert(Self.realPath(path) ?? path).inserted else { return }
            let fileName = AppScanner.fileName(of: path)
            let info = reader.infoDictionary(ofBundleAt: path) ?? [:]
            let localized = reader.localizedTable(
                "InfoPlist", inBundleAt: path, developmentRegion: info["CFBundleDevelopmentRegion"] as? String)
            let name = AppNaming.finderName(localized: localized, info: info, fileName: fileName)
            let bundleID = (info["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            found.append(
                InstalledApp(
                    key: "", bundleID: bundleID, name: name, path: path,
                    keywords: AppNaming.keywords(name: name, localized: localized, info: info, fileName: fileName),
                    isSystem: root.isSystem))
        }

        /// True for a folder, following a symlink.
        private static func isFolder(_ path: String, type: UInt8) -> Bool {
            if type == UInt8(DT_DIR) { return true }
            guard type == UInt8(DT_LNK) || type == UInt8(DT_UNKNOWN) else { return false }
            var info = stat()
            return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
        }

        private static func realPath(_ path: String) -> String? {
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }
}
