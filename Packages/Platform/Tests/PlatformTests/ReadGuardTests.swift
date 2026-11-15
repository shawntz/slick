import CoreGraphics
import Foundation
import Kit
import KitHosting
import KitTesting
import Testing

@testable import Platform

/// The read guard keeps background reads out of places where macOS could ask the user. Every path
/// here is synthetic or under a temporary folder; nothing reads a protected place.
@Suite(.timeLimit(.minutes(1))) struct ReadGuardTests {
    static let home = URL(filePath: "/synthetic/home", directoryHint: .isDirectory)

    static func needed(_ path: String) -> [Permission] {
        ProtectedLocations.permissionsNeeded(toRead: URL(filePath: path), home: home)
    }

    @Test func protectedPlacesAreFoundByTheirPath() {
        #expect(Self.needed("/synthetic/home/Desktop/report.pdf") == [.protectedFolder(.desktop)])
        #expect(Self.needed("/synthetic/home/Documents") == [.protectedFolder(.documents)])
        #expect(Self.needed("/synthetic/home/downloads/Tool.app") == [.protectedFolder(.downloads)])
        #expect(
            Self.needed("/Volumes/SYNTHETIC/notes.txt") == [
                .protectedFolder(.removableVolumes), .protectedFolder(.networkVolumes),
            ])
        for library in ["Containers/com.example.other", "Group Containers/x", "Mobile Documents", "CloudStorage/y"] {
            #expect(Self.needed("/synthetic/home/Library/" + library + "/file") == [.fullDiskAccess], "\(library)")
        }
        // Places no permission guards.
        for path in [
            "/Applications/Example.app", "/synthetic/home/Applications/Example.app",
            "/synthetic/home/Library/Application Support/Example", "/synthetic/home/DesktopNotes/file",
            "/synthetic/home/Developer/build/Example.app", "/Volumes", "/System/Applications/Example.app",
        ] {
            #expect(Self.needed(path).isEmpty, "\(path)")
        }
    }

    @Test func theLiveGuardAllowsAProtectedPlaceOnlyOnceEveryPermissionIsGranted() {
        let permissions = FakePermissions(defaultStatus: .notDetermined)
        let readGuard = ReadGuard.permissions(permissions, home: Self.home)
        let downloads = URL(filePath: "/synthetic/home/Downloads/Tool.app")
        let volume = URL(filePath: "/Volumes/SYNTHETIC/file.txt")
        #expect(readGuard.mayRead(URL(filePath: "/Applications/Example.app")))
        #expect(!readGuard.mayRead(downloads))
        permissions.set(.protectedFolder(.downloads), to: .granted)
        #expect(readGuard.mayRead(downloads))
        permissions.set(.protectedFolder(.removableVolumes), to: .granted)
        #expect(!readGuard.mayRead(volume))
        permissions.set(.protectedFolder(.networkVolumes), to: .granted)
        #expect(readGuard.mayRead(volume))
        #expect(permissions.requests.isEmpty)
    }

    /// Found in review: the icon loader drew a file in Downloads, or an app run from there, by
    /// reading it, which could raise the folder prompt while the user only looked at a list.
    @Test @MainActor func theIconLoaderDrawsGuardedFilesAndAppsWithoutReadingThem() async throws {
        let root = TemporaryFolder()
        let renderer = CountingRenderer()
        let downloads = "/synthetic/home/Downloads/"
        let readGuard = ReadGuard { !$0.path(percentEncoded: false).hasPrefix(downloads) }
        let apps = StaticAppIcons([
            AppIconEntry(
                bundleID: "com.example.downloaded", url: URL(filePath: downloads + "Tool.app"), stamp: "v1")
        ])
        let cache = IconCache(
            folders: IconCache.Folders(
                atlas: root.url.appending(path: "atlas"), favicons: root.url.appending(path: "favicons"),
                remote: root.url.appending(path: "remote")),
            renderer: renderer, apps: apps, http: FakeHTTP(),
            settings: PlatformSettings(backend: MemorySettingsBackend()),
            readGuard: readGuard)
        let size = IconSize(points: 64, scale: 2)  // larger than any atlas, so drawn on its own
        func typeColor(_ type: String) -> RGB { RGB(SyntheticIconRenderer.color(for: "type:" + type)) }

        let document = try await loaded {
            cache.image(for: .file(path: downloads + "Report.pdf"), size: size, isDark: false)
        }
        #expect(center(of: document) == typeColor("pdf"))
        let folder = try await loaded {
            cache.image(for: .file(path: downloads + "Project"), size: size, isDark: false)
        }
        #expect(center(of: folder) == typeColor("public.folder"))
        let app = try await loaded {
            cache.image(for: .app(bundleID: "com.example.downloaded"), size: size, isDark: false)
        }
        #expect(center(of: app) == typeColor("com.apple.application-bundle"))
        #expect(renderer.appDraws == 0)
        // An image file there gets the placeholder; without the guard a missing file draws nothing.
        _ = try await loaded { cache.image(for: .image(path: downloads + "photo.png"), size: size, isDark: false) }
        // Elsewhere the file itself is drawn.
        let other = try await loaded {
            cache.image(for: .file(path: "/synthetic/other/Report.pdf"), size: size, isDark: false)
        }
        #expect(center(of: other) == RGB(SyntheticIconRenderer.color(for: "file:/synthetic/other/Report.pdf")))
        withExtendedLifetime(root) {}
    }

    @Test func theAtlasLeavesOutAppsTheGuardKeeps() {
        let catalog = ApplicationCatalog(folders: [])
        catalog.insert([
            AppInfo(
                bundleID: "com.example.kept", name: "Kept", url: URL(filePath: "/synthetic/home/Downloads/Kept.app")),
            AppInfo(bundleID: "com.example.listed", name: "Listed", url: URL(filePath: "/synthetic/apps/Listed.app")),
        ])
        let readGuard = ReadGuard { !$0.path(percentEncoded: false).contains("/Downloads/") }
        let entries = CatalogAppIcons(catalog: catalog, readGuard: readGuard).appIconEntries()
        #expect(entries.map(\.bundleID) == ["com.example.listed"])
    }

    @Test func aCatalogLookupNeverReadsAnAppTheGuardKeeps() async throws {
        let folder = TemporaryFolder()
        let app = try folder.makeApp("Guarded.app", info: ["CFBundleIdentifier": "com.example.guarded"])
        let located = Counter()
        let locate: @Sendable (String) -> URL? = { _ in
            located.increment()
            return app
        }
        let guarded = ApplicationCatalog(folders: [], locate: locate, readGuard: ReadGuard { _ in false })
        #expect(guarded.application(bundleID: "com.example.guarded") == nil)
        try await waitUntil { located.value == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(guarded.application(bundleID: "com.example.guarded") == nil)

        let open = ApplicationCatalog(folders: [], locate: locate)
        _ = open.application(bundleID: "com.example.guarded")
        try await waitUntil { open.application(bundleID: "com.example.guarded") != nil }
        withExtendedLifetime(folder) {}
    }
}
