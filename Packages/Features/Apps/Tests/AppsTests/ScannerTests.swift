import Foundation
import Kit
import Testing

@testable import Apps

@Suite("Scanning applications", .timeLimit(.minutes(1)))
struct ScannerTests {
    private func scan(_ tree: AppTree, languages: [String] = ["en"], extra: [URL] = []) async -> [InstalledApp] {
        let library = tree.library(languages: languages)
        return await library.applications(in: library.roots(adding: extra))
    }

    private func app(_ apps: [InstalledApp], _ name: String) throws -> InstalledApp {
        try #require(apps.first { $0.name == name }, "no app named \(name)")
    }

    @Test func findsAppsInEveryRootInRootOrder() async throws {
        let tree = try AppTree()
        let names = await scan(tree).map(\.name)
        #expect(
            names == [
                "Found Deep", "Linked Browser", "Folder App", "Nameless", "Plain", "Pocket Game", "Sample Editor",
                "Sample Editor Beta", "Settings Like", "Sample Monitor", "Suite Sheets", "Writer Pro", "Sample Notes",
                "Web App", "Finder Like",
            ])
    }

    @Test func treatsBundlesAsLeavesAndSkipsHiddenNames() async throws {
        let names = Set(await scan(try AppTree()).map(\.name))
        #expect(!names.contains("Editor Helper"), "an app inside an app is a helper")
        #expect(!names.contains { $0.contains("Hidden") }, "dot names are skipped")
    }

    @Test func readsFoldersOnlyAsDeepAsTheRootSays() async throws {
        let names = Set(await scan(try AppTree()).map(\.name))
        #expect(names.contains("Found Deep"))
        #expect(!names.contains("Too Deep"))
    }

    @Test func followsLinksAndCountsOneBundleOnce() async throws {
        let tree = try AppTree()
        let apps = await scan(tree)
        let browsers = apps.filter { $0.bundleID == "com.example.browser" }
        #expect(browsers.count == 1)
        #expect(browsers.first?.path == tree.path("Applications/Linked Browser.app"), "the link keeps its own path")
        #expect(apps.contains { $0.name == "Folder App" }, "a linked folder is read too")
    }

    @Test func readsOnlyTheAllowlistInCoreServices() async throws {
        let names = Set(await scan(try AppTree()).map(\.name))
        #expect(names.contains("Finder Like"))
        #expect(!names.contains("Agent"))
    }

    @Test func namesAreWhatFinderShowsAndOtherNamesAreKeywords() async throws {
        let apps = await scan(try AppTree())
        #expect(try app(apps, "Sample Editor").keywords.contains("Editor"), "the bundle name is a keyword")
        // The bundle's names are shorter than its file name, so Finder shows the file name.
        #expect(try app(apps, "Writer Pro").keywords == ["Writer", "WriterPro"])
        #expect(try app(apps, "Nameless").bundleID == nil)
        #expect(try app(apps, "Plain").keywords.isEmpty, "a bundle with no names of its own")
        #expect(try app(apps, "Pocket Game").bundleID == "com.example.pocket-game", "a wrapped iOS app")
        for app in apps where !app.key.contains("@") {
            let shown = FileManager.default.displayName(atPath: app.path)
            #expect(app.name == AppScanner.fileName(of: shown), "the system's name for \(app.path)")
        }
    }

    @Test func picksTheUsersLanguageFromALoctableOrStringsFilesForKeywords() async throws {
        let tree = try AppTree()
        let german = await scan(tree, languages: ["de-DE", "en"])
        #expect(try app(german, "Sample Editor").keywords.contains("Beispiel-Editor"), "from InfoPlist.loctable")
        #expect(
            try app(german, "Sample Notes").keywords.contains("Notizen"), "from de.lproj/InfoPlist.strings in UTF-16")
        let english = await scan(tree, languages: ["en-GB"])
        #expect(try !app(english, "Sample Notes").keywords.contains("Notizen"))
    }

    @Test func keywordsHoldOtherNamesAlternatesAndTheWellKnownTable() async throws {
        let settings = try app(await scan(try AppTree()), "Settings Like")
        #expect(settings.keywords.contains("Preferences"), "CFBundleAlternateNames")
        #expect(settings.keywords.contains("control panel"), "the table, by bundle ID")
        #expect(!settings.keywords.contains("Settings Like"), "never the name itself")
    }

    @Test func aSecondCopyOfAnAppGetsItsPathInTheKeyAndItsFileNameAsTitle() async throws {
        let tree = try AppTree()
        let copies = await scan(tree).filter { $0.bundleID == "com.example.editor" }
        #expect(
            copies.map(\.key) == [
                "com.example.editor", "com.example.editor@" + tree.path("Applications/Sample Editor Beta.app"),
            ])
        #expect(copies.map(\.name) == ["Sample Editor", "Sample Editor Beta"])
        #expect(copies.map(\.reference.opensByBundleID) == [true, false])
    }

    @Test func anAppWithoutABundleIDIsKeyedByPath() async throws {
        let tree = try AppTree()
        #expect(try app(await scan(tree), "Nameless").key == tree.path("Applications/Nameless.app"))
    }

    @Test func marksAppsUnderSystemRoots() async throws {
        let apps = await scan(try AppTree())
        #expect(try app(apps, "Sample Notes").isSystem)
        #expect(try !app(apps, "Plain").isSystem)
    }

    @Test func readsExtraFoldersTwoLevelsDeep() async throws {
        let tree = try AppTree()
        #expect(await scan(tree, extra: [tree.extra]).contains { $0.name == "Extra Tool" })
    }

    @Test func aMissingFolderScansAsEmpty() async throws {
        let library = FolderAppLibrary(
            standardRoots: [AppScanRoot(URL(filePath: "/nonexistent-\(UUID().uuidString)"), depth: 2)],
            extensionsFolder: nil, reader: BundleReader(languages: ["en"]))
        #expect(await library.applications(in: library.roots(adding: [])).isEmpty)
        #expect(await library.settingsPanes().isEmpty)
    }

    @Test func theLiveRootsListTheStandardFoldersInOrder() {
        let roots = FolderAppLibrary.system(home: URL(filePath: "/Users/example"), languages: ["en"]).standardRoots
        #expect(
            roots.map(\.folder.path) == [
                "/Applications", "/Applications/Utilities", "/System/Applications", "/Users/example/Applications",
                "/System/Library/CoreServices/Applications", "/System/Library/CoreServices",
            ])
        #expect(roots.last?.only?.contains("Finder.app") == true)
    }
}
