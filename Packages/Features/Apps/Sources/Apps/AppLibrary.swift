import Foundation
import Kit

/// What is installed: the applications in their folders and the System Settings panes. Only this
/// feature needs it, so it lives here behind ``AppLibraryKey`` rather than in Kit.
///
/// Every requirement that reads the disk is `@concurrent`, so it runs off the main thread whoever
/// calls it.
nonisolated protocol AppLibrary: Sendable {
    /// The folders that hold applications, followed by the extra folders the user added.
    func roots(adding extraFolders: [URL]) -> [AppScanRoot]

    /// Every application in the folders.
    @concurrent func applications(in roots: [AppScanRoot]) async -> [InstalledApp]

    /// Every System Settings pane that deep links can open, with its anchors.
    @concurrent func settingsPanes() async -> [SystemSettingsPane]
}

/// The library for each kind of run. The app reads the real folders. Scenarios, self-tests and
/// benchmarks read a small synthetic tree in the run's cache folder, so they never show the
/// user's apps. Tests pass a ``FolderAppLibrary`` over a tree of their own.
nonisolated enum AppLibraryKey: FeatureServiceKey {
    static func live(_ context: FeatureContext) -> any AppLibrary {
        FolderAppLibrary.system(home: context.storage.homeDirectory, languages: Locale.preferredLanguages)
    }

    static func isolated(_ context: FeatureContext) -> any AppLibrary {
        SyntheticApps.library(in: context.storage.cacheDirectory.appending(path: "synthetic-apps"))
    }
}

/// A library that scans folders on disk: the system's in the app, a synthetic tree elsewhere.
nonisolated struct FolderAppLibrary: AppLibrary {
    /// The standard application folders, in the order that picks the first copy of an app.
    var standardRoots: [AppScanRoot]
    /// Where the System Settings extensions live, or nil for none.
    var extensionsFolder: URL?
    var reader: BundleReader
    /// Runs before each scan. The synthetic library writes its tree here, never in `init`.
    var prepare: @Sendable () -> Void = {}

    /// How deep the scan reads a folder the user added: the folder and its subfolders.
    static let extraFolderDepth = 2

    func roots(adding extraFolders: [URL]) -> [AppScanRoot] {
        standardRoots + extraFolders.map { AppScanRoot($0, depth: Self.extraFolderDepth) }
    }

    @concurrent func applications(in roots: [AppScanRoot]) async -> [InstalledApp] {
        prepare()
        return AppScanner(reader: reader).scan(roots)
    }

    @concurrent func settingsPanes() async -> [SystemSettingsPane] {
        prepare()
        guard let extensionsFolder else { return [] }
        return SettingsPaneScanner(reader: reader).scan(folder: extensionsFolder)
    }

    /// The real folders. `home` is the user's home folder, for `~/Applications`.
    static func system(home: URL, languages: [String]) -> FolderAppLibrary {
        FolderAppLibrary(
            standardRoots: standardRoots(home: home),
            extensionsFolder: URL(filePath: "/System/Library/ExtensionKit/Extensions"),
            reader: BundleReader(languages: languages))
    }

    /// The folders the lab found user-facing apps in on macOS 27.2, `/Applications` first.
    /// `/Applications` and `~/Applications` hold vendor and web-app subfolders, so they are read four
    /// levels deep. `/System/Library/CoreServices` holds 124 bundles, 92 of them agents, so only an
    /// allowlist counts there.
    static func standardRoots(home: URL) -> [AppScanRoot] {
        [
            AppScanRoot(URL(filePath: "/Applications"), depth: 4),
            AppScanRoot(URL(filePath: "/Applications/Utilities"), depth: 1),
            AppScanRoot(URL(filePath: "/System/Applications"), depth: 2, isSystem: true),
            AppScanRoot(home.appending(path: "Applications"), depth: 4),
            AppScanRoot(URL(filePath: "/System/Library/CoreServices/Applications"), depth: 1, isSystem: true),
            AppScanRoot(
                URL(filePath: "/System/Library/CoreServices"), depth: 1, only: coreServicesAllowlist, isSystem: true),
        ]
    }

    /// The apps in `/System/Library/CoreServices` that people open themselves.
    static let coreServicesAllowlist: Set<String> = [
        "Accessibility Reader.app", "Batteries.app", "Certificate Assistant.app", "Finder.app",
        "Pro Display Calibrator.app", "Screen Time.app", "Siri.app", "Software Update.app", "Spotlight.app",
    ]
}
