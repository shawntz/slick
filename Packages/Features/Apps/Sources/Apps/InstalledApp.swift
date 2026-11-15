import Foundation
import Kit

/// One application found on disk. A plain value, built off the main thread by the scan.
nonisolated struct InstalledApp: Hashable, Sendable {
    /// The row key: the bundle ID for the first copy found, the bundle ID and path for a second copy
    /// of the same app, and the path for a bundle with no ID.
    var key: String
    var bundleID: String?
    /// The name Finder shows. See ``AppNaming/finderName(localized:info:fileName:)``. A second copy
    /// of an app shows its file name.
    var name: String
    /// The bundle where the scan found it. A symlink keeps its own path, as `/Applications/Safari.app`
    /// does, so Finder shows the place the user knows.
    var path: String
    /// Other names the app answers to: its other bundle names, the file name and well-known alternates.
    var keywords: [String]
    /// True for apps on the system volume, which cannot be moved to the Trash.
    var isSystem: Bool

    var reference: AppReference {
        AppReference(key: key, bundleID: bundleID, name: name, path: path, isSystem: isSystem)
    }
}

/// What a row carries so its actions can be built from the row alone, also after a relaunch.
/// About 150 bytes as JSON.
nonisolated struct AppReference: Codable, Hashable, Sendable {
    var key: String
    var bundleID: String?
    var name: String
    var path: String
    var isSystem: Bool

    var url: URL { URL(filePath: path, directoryHint: .isDirectory) }

    /// True when ``key`` is the bare bundle ID, so asking the system to open that bundle ID opens
    /// this copy. A second copy of an app opens by path instead.
    var opensByBundleID: Bool { bundleID != nil && key == bundleID }

    /// True when a running app is this one: the same bundle ID, or the same bundle path when the app
    /// has no ID.
    func matches(_ app: RunningApp) -> Bool {
        if let bundleID { return app.bundleID == bundleID }
        return app.path == path
    }
}

/// A folder the scan reads, and how.
nonisolated struct AppScanRoot: Hashable, Sendable {
    var folder: URL
    /// How many folder levels to read: 1 reads only the folder's own entries, 2 also its subfolders.
    var depth: Int
    /// When set, only bundles with these file names count, and subfolders are not read. For
    /// `/System/Library/CoreServices`, where most bundles are agents nobody opens.
    var only: Set<String>?
    /// Apps here live on the system volume.
    var isSystem: Bool

    init(_ folder: URL, depth: Int, only: Set<String>? = nil, isSystem: Bool = false) {
        self.folder = folder
        self.depth = depth
        self.only = only
        self.isSystem = isSystem
    }
}

/// One System Settings pane and the sections inside it that it lets other apps open.
nonisolated struct SystemSettingsPane: Hashable, Sendable {
    /// The extension's bundle ID, which the deep link names.
    var id: String
    var name: String
    /// The extension bundle. Its Finder icon is the pane's sidebar icon.
    var path: String
    var anchors: [Anchor]

    /// A section of a pane that a deep link can open, such as Privacy & Security's Accessibility list.
    struct Anchor: Hashable, Sendable {
        /// The anchor name the deep link carries, such as `Privacy_Accessibility`.
        var id: String
        var title: String
        /// The words System Settings itself searches for this anchor, plus its other titles.
        var keywords: [String]
    }
}
