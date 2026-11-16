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
        for library in ["Containers/com.example.other", "Group Containers/x", "CloudStorage/y"] {
            #expect(Self.needed("/synthetic/home/Library/" + library + "/file") == [.fullDiskAccess], "\(library)")
        }
        // Everything in Mobile Documents is iCloud's, and only iCloud Drive's own grant opens it.
        for library in ["Mobile Documents", "Mobile Documents/com~apple~CloudDocs/a.txt", "mobile documents/x/y"] {
            #expect(Self.needed("/synthetic/home/Library/" + library) == [.protectedFolder(.iCloudDrive)], "\(library)")
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

    /// Found in the second review: the data volume names every home folder a second time through a
    /// firmlink, which is not a symbolic link, and the Contacts, Calendars and Photos libraries were
    /// not listed. Every path here is made up and nothing reads it.
    @Test func theDataVolumeSpellingAndPersonalLibrariesAreProtectedToo() {
        let data = "/System/Volumes/Data"
        #expect(Self.needed(data + "/synthetic/home/Downloads/report.pdf") == [.protectedFolder(.downloads)])
        #expect(Self.needed("/system/volumes/DATA/synthetic/home/Desktop") == [.protectedFolder(.desktop)])
        #expect(
            Self.needed(data + "/Volumes/SYNTHETIC/notes.txt") == [
                .protectedFolder(.removableVolumes), .protectedFolder(.networkVolumes),
            ])
        #expect(Self.needed(data + "/synthetic/home/Library/Mail/x") == [.fullDiskAccess])
        for library in [
            "Library/Application Support/AddressBook/Sources/x/AddressBook-v22.abcddb",
            "Library/Calendars/x.caldav/Info.plist", "Library/Reminders/x", "Library/Cookies/Cookies.binarycookies",
            "Library/HomeKit/core.sqlite", "Library/Suggestions/snippets.db",
            "Library/Application Support/CallHistoryDB/CallHistory.storedata",
            "Library/Application Support/com.apple.TCC/TCC.db",
            "Pictures/Photos Library.photoslibrary/database/Photos.sqlite",
        ] {
            #expect(Self.needed("/synthetic/home/" + library) == [.fullDiskAccess], "\(library)")
            #expect(Self.needed(data + "/synthetic/home/" + library) == [.fullDiskAccess], "\(library)")
        }
        // A Photos library can live anywhere, and the system guards whichever one it uses.
        #expect(Self.needed("/synthetic/other/Shared.photoslibrary/originals/a.heic") == [.fullDiskAccess])
        // Places no permission guards, in either spelling.
        for path in [
            data, data + "/Applications/Example.app", data + "/synthetic/home/Library/Application Support/Example",
            "/System/Volumes/DataNotes/x", "/synthetic/home/Pictures/holiday.photoslibrary-notes.txt",
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

    /// Found in review: the guard judged the path as written, so a link outside the protected
    /// folders that leads into one passed it. Every link here is made up, in a temporary folder
    /// whose own made-up `home/Downloads` stands for the protected folder.
    @Test func aLinkIntoAProtectedPlaceCountsAsThatPlace() throws {
        let folder = TemporaryFolder()
        let manager = FileManager.default
        let home = folder.url.appending(path: "home", directoryHint: .isDirectory)
        let downloads = home.appending(path: "Downloads", directoryHint: .isDirectory)
        let elsewhere = folder.url.appending(path: "elsewhere", directoryHint: .isDirectory)
        try manager.createDirectory(at: downloads, withIntermediateDirectories: true)
        try manager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("pdf".utf8).write(to: downloads.appending(path: "report.pdf"))
        try Data("plain".utf8).write(to: elsewhere.appending(path: "plain.txt"))
        func link(_ name: String, to destination: String) throws -> URL {
            let url = elsewhere.appending(path: name)
            try manager.createSymbolicLink(atPath: url.path(percentEncoded: false), withDestinationPath: destination)
            return url
        }
        let toReport = try link("report.pdf", to: downloads.appending(path: "report.pdf").path(percentEncoded: false))
        let relative = try link("relative", to: "../home/Downloads")
        let toVolume = try link("volume", to: "/Volumes/SYNTHETIC")
        let toPlain = try link("to-plain.txt", to: "plain.txt")
        let loop = try link("loop-a", to: "loop-b")
        _ = try link("loop-b", to: "loop-a")

        let permissions = FakePermissions(defaultStatus: .notDetermined)
        let readGuard = ReadGuard.permissions(permissions, home: home)
        #expect(!readGuard.mayRead(toReport))
        #expect(!readGuard.mayRead(relative.appending(path: "report.pdf")))
        #expect(!readGuard.mayRead(toVolume.appending(path: "notes.txt")))
        #expect(!readGuard.mayRead(loop), "a loop of links")
        #expect(readGuard.mayRead(elsewhere.appending(path: "plain.txt")))
        #expect(readGuard.mayRead(toPlain))
        #expect(readGuard.mayRead(elsewhere.appending(path: "missing.txt")))

        permissions.set(.protectedFolder(.downloads), to: .granted)
        #expect(readGuard.mayRead(toReport))
        #expect(readGuard.mayRead(relative.appending(path: "report.pdf")))
        #expect(permissions.requests.isEmpty)
    }

    /// Finding a link must not itself read in a protected place: the walk asks about a part only
    /// once the path up to it needs nothing missing.
    @Test func theWalkNeverAsksAboutAPartInAProtectedPlace() {
        let home = URL(filePath: "/synthetic/home", directoryHint: .isDirectory)
        let links = [
            "/synthetic/other/link": "/synthetic/home/Downloads/inner", "/synthetic/home/Downloads/inner": "/x",
        ]
        var asked: [String] = []
        let lookUp: (String) -> String? = { path in
            asked.append(path)
            return links[path]
        }
        let missing: (Permission) -> Bool = { _ in false }
        let throughLink = URL(filePath: "/synthetic/other/link/file")
        #expect(!ProtectedLocations.mayRead(throughLink, home: home, isGranted: missing, linkDestination: lookUp))
        #expect(asked.contains("/synthetic/other/link"), "the link was found")
        #expect(!asked.contains { $0.hasPrefix("/synthetic/home/Downloads") })
        asked = []
        let inside = URL(filePath: "/synthetic/home/Downloads/inner")
        #expect(!ProtectedLocations.mayRead(inside, home: home, isGranted: missing, linkDestination: lookUp))
        #expect(asked.isEmpty, "the path as written is judged first")
        #expect(ProtectedLocations.mayRead(throughLink, home: home, isGranted: { _ in true }, linkDestination: lookUp))
        #expect(ProtectedLocations.walk("/a/./b/../c", linkDestination: { _ in nil }, allows: { _ in true }) == "/a/c")
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
