import Foundation
import Kit
import Testing

@testable import Apps

/// An app's title is the name Finder shows. The scan works it out from the bundle's own files and
/// never asks the system, so these made-up bundles are never registered on the Mac that runs the
/// tests.
@Suite("Naming apps as Finder does", .timeLimit(.minutes(1)))
struct AppNamingTests {
    /// A fresh folder of bundles, removed when the value is released.
    nonisolated final class Folder: Sendable {
        let url = FileManager.default.temporaryDirectory.appending(path: "apps-names-\(UUID().uuidString)")

        deinit {
            try? FileManager.default.removeItem(at: url)
        }

        /// A library that scans only this folder.
        func library(languages: [String] = ["en"]) -> FolderAppLibrary {
            FolderAppLibrary(
                standardRoots: [AppScanRoot(url, depth: 1)], extensionsFolder: nil,
                reader: BundleReader(languages: languages), prepare: { withExtendedLifetime(self) {} })
        }

        func scan(languages: [String] = ["en"]) async -> [InstalledApp] {
            let library = library(languages: languages)
            return await library.applications(in: library.roots(adding: []))
        }
    }

    /// Writes the bundles every test reads.
    private func folder() throws -> Folder {
        let folder = Folder()
        // A display name that matches the file name: the localized name shows.
        try SyntheticApps.writeApp(
            at: folder.url.appending(path: "Atlas.app"), bundleID: "com.example.atlas",
            info: ["CFBundleDisplayName": "Atlas", "CFBundleName": "Atlas", "CFBundleDevelopmentRegion": "en"],
            localized: ["en": ["CFBundleDisplayName": "Atlas Maps"], "de": ["CFBundleDisplayName": "Atlas Karten"]])
        // Bundle names shorter than the file name: the file name shows.
        try SyntheticApps.writeApp(
            at: folder.url.appending(path: "Code Studio.app"), bundleID: "com.example.code-studio",
            info: ["CFBundleDisplayName": "Code", "CFBundleName": "Code"])
        // A bundle name longer than the file name: the file name still shows.
        try SyntheticApps.writeApp(
            at: folder.url.appending(path: "Short.app"), bundleID: "com.example.short",
            info: ["CFBundleName": "Short Name Longer"])
        return folder
    }

    private func app(_ apps: [InstalledApp], _ name: String) throws -> InstalledApp {
        try #require(apps.first { $0.name == name }, "no app named \(name) in \(apps.map(\.name))")
    }

    @Test func titlesFollowFindersRuleAndOtherNamesAreKeywords() async throws {
        let folder = try folder()
        let apps = await folder.scan()
        #expect(apps.map(\.name) == ["Atlas Maps", "Code Studio", "Short"])
        #expect(try app(apps, "Atlas Maps").keywords == ["Atlas"])
        #expect(try app(apps, "Code Studio").keywords == ["Code"])
        #expect(try app(apps, "Short").keywords == ["Short Name Longer"])
    }

    @Test func theScanPicksTheUsersLanguage() async throws {
        let folder = try folder()
        let apps = await folder.scan(languages: ["de-DE", "en"])
        #expect(apps.map(\.name) == ["Atlas Karten", "Code Studio", "Short"])
    }

    @Test func anAppRenamedOnDiskShowsItsNewFileName() async throws {
        let folder = try folder()
        let manager = FileManager.default
        try manager.moveItem(
            at: folder.url.appending(path: "Atlas.app"), to: folder.url.appending(path: "Field Maps.app"))
        let apps = await folder.scan()
        #expect(apps.map(\.name) == ["Code Studio", "Field Maps", "Short"])
        let renamed = try app(apps, "Field Maps")
        #expect(renamed.bundleID == "com.example.atlas")
        #expect(renamed.keywords == ["Atlas Maps", "Atlas"], "the bundle's own names still find it")
    }

    @Test func theRuleComparesTheFileNameWithTheDisplayName() {
        let info: [String: Any] = ["CFBundleDisplayName": "Globe", "CFBundleName": "Globe"]
        let german = ["CFBundleDisplayName": "Globus"]
        #expect(AppNaming.finderName(localized: german, info: info, fileName: "Globe") == "Globus")
        #expect(AppNaming.finderName(localized: [:], info: info, fileName: "Globe") == "Globe")
        #expect(AppNaming.finderName(localized: german, info: info, fileName: "Weltkarte") == "Weltkarte")
        #expect(AppNaming.finderName(localized: german, info: [:], fileName: "Globe") == "Globe")
    }

    /// Activity Monitor has no display name in its Info.plist. Its bundle name stands in, and its
    /// localization may translate either key.
    @Test func aBundleWithNoDisplayNameIsComparedByItsBundleName() {
        let info: [String: Any] = ["CFBundleName": "Process Viewer"]
        #expect(
            AppNaming.finderName(
                localized: ["CFBundleName": "Prozessanzeige"], info: info, fileName: "Process Viewer")
                == "Prozessanzeige")
        #expect(
            AppNaming.finderName(
                localized: ["CFBundleDisplayName": "Prozesse"], info: info, fileName: "Process Viewer") == "Prozesse")
        #expect(
            AppNaming.finderName(localized: ["CFBundleName": "Prozessanzeige"], info: info, fileName: "Viewer")
                == "Viewer")
        // A display name that differs from the file name wins over a bundle name that matches it.
        let both: [String: Any] = ["CFBundleDisplayName": "Viewer Pro", "CFBundleName": "Viewer"]
        #expect(
            AppNaming.finderName(localized: ["CFBundleName": "Anzeige"], info: both, fileName: "Viewer") == "Viewer")
    }

    /// Some localizations put soft hyphens inside long words. Left in, they would split the word
    /// for search.
    @Test func softHyphensAreRemovedFromLocalizedNames() {
        let info: [String: Any] = ["CFBundleDisplayName": "Machine Settings"]
        let name = AppNaming.finderName(
            localized: ["CFBundleDisplayName": "Maschinen\u{00AD}einstellungen"], info: info,
            fileName: "Machine Settings")
        #expect(name == "Maschineneinstellungen")
        #expect(AppNaming.shownText("  \u{00AD} ") == nil)
        #expect(AppNaming.shownText(7) == nil)
    }
}
