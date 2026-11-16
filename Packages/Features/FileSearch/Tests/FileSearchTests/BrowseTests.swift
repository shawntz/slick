import CoreBridge
import Darwin
import Foundation
import Kit
import KitTesting
import Testing

@testable import FileSearch

/// Folders outside the index, listed from disk. Every folder here lies in the test's own temporary
/// tree: "elsewhere" stands for a folder outside the home folder, such as /Applications.
@Suite("Browsing folders outside the index", .timeLimit(.minutes(1)))
@MainActor
struct BrowseTests {
    /// A folder beside the synthetic home, with a few files and links.
    private func elsewhere(_ tree: TestTree) throws -> String {
        let folder = tree.root.path(percentEncoded: false).trimmingSuffix("/") + "/elsewhere"
        try FileManager.default.createDirectory(atPath: folder + "/Tools", withIntermediateDirectories: true)
        for name in ["report.txt", "Reader.app.txt", "spare-report.txt", ".hidden-note"] {
            #expect(FileManager.default.createFile(atPath: folder + "/" + name, contents: Data("x".utf8)))
        }
        #expect(symlink(tree.path("Desktop"), folder + "/to-desktop") == 0)
        #expect(symlink(tree.home, folder + "/to-home") == 0)
        return folder
    }

    @Test func aFolderOutsideTheIndexIsListedFromDisk() async throws {
        let fixture = try Fixture()
        let folder = try elsewhere(fixture.tree)
        try await fixture.start()
        let rows = try await fixture.harness.asyncSections(for: folder + "/").flatMap(\.rows)
        #expect(
            rows.map(\.title) == ["Reader.app.txt", "Tools", "report.txt", "spare-report.txt", "to-desktop", "to-home"])
        #expect(rows.first { $0.title == "Tools" }?.completion == folder + "/Tools/", "folders complete on Tab")
        #expect(rows.first { $0.title == "to-home" }?.completion == nil, "a link is listed, never followed")
        #expect(fixture.fileSystem.listed == [folder])

        let filtered = try await fixture.harness.asyncSections(for: folder + "/rep").flatMap(\.rows)
        #expect(filtered.map(\.title) == ["report.txt", "spare-report.txt"], "names that start with it come first")
        #expect(filtered.map(\.titleHighlights) == [[0..<3], [6..<9]])
        #expect(
            try await fixture.rootTitles(folder + "/.hid").isEmpty,
            "hidden names stay out of a listing, as out of the index, until the setting includes them")
    }

    @Test func theHomeFolderAndWhatItHidesAreNeverListed() async throws {
        let fixture = try Fixture()
        let folder = try elsewhere(fixture.tree)
        try await fixture.start()
        for query in [
            "~/Library/", "~/Library/Caches/", "~/Desktop/", folder + "/to-desktop/", folder + "/to-home/",
            folder + "/to-home/Library/", fixture.tree.home.uppercased() + "/Library/",
        ] {
            #expect(try await fixture.rootPaths(query).isEmpty, "\(query)")
        }
        #expect(fixture.fileSystem.listed.isEmpty)
        #expect(fixture.fileSystem.refused.count == 7)
    }

    @Test func theSearchFilesPageListsTheFolderWithoutAPreview() async throws {
        let fixture = try Fixture()
        let folder = try elsewhere(fixture.tree)
        try await fixture.start()
        try await fixture.harness.run("search")
        try await fixture.harness.setQuery(folder + "/report")
        #expect(fixture.harness.rows.map(\.title) == ["report.txt", "spare-report.txt"])
        #expect(try await fixture.harness.loadDetail() == nil, "a file outside the searched places shows no preview")
        #expect(fixture.fileSystem.factsRead.isEmpty)
        try await fixture.harness.setQuery("~/Library/")
        #expect(fixture.harness.rows.isEmpty)
        #expect(fixture.harness.page?.emptyState?.title == "Folder Not Searched")
    }

    @Test func outsideTheAppNothingIsListedFromDisk() async throws {
        let harness = FeatureHarness(FileSearchFeature.self, fakes: FakeServices(permissions: .notDetermined))
        await harness.activate()
        await harness.feature.waitUntilIdle()
        #expect(try await harness.asyncSections(for: "/").flatMap(\.rows).isEmpty)
        await harness.deactivate()
    }

    @Test func theGuardRefusesEverySpellingOfARefusedFolder() throws {
        let tree = try TestTree()
        let folder = try elsewhere(tree)
        let open = BrowseGuard(refused: [tree.home], devices: nil)
        #expect(open.listablePath(folder) == folder)
        #expect(open.listablePath(folder + "/Tools/../Tools") == folder + "/Tools")
        #expect(open.listablePath(folder + "/report.txt") == nil, "a file is not a folder")
        #expect(open.listablePath(folder + "/missing") == nil)
        #expect(open.listablePath(tree.home) == nil)
        #expect(open.listablePath(tree.home + "/Projects") == nil)
        #expect(open.listablePath(folder + "/to-home") == nil, "a link is never followed")
        #expect(open.listablePath("relative") == nil)
        // A refused folder named through a link is refused under its real spelling too.
        let byLink = BrowseGuard(refused: [folder + "/to-home"], devices: nil)
        #expect(byLink.listablePath(tree.home + "/Projects") == nil)
        #expect(byLink.listablePath(folder) == folder)
        // Only the devices given are allowed.
        var info = stat()
        #expect(lstat(folder, &info) == 0)
        #expect(BrowseGuard(refused: [], devices: [info.st_dev]).listablePath(folder) == folder)
        #expect(BrowseGuard(refused: [], devices: [info.st_dev &+ 1]).listablePath(folder) == nil)
        #expect(BrowseGuard.systemSpelling("/tmp/a") == "/private/tmp/a")
        #expect(BrowseGuard.systemSpelling("/tmpx") == "/tmpx")
    }

    @Test func aQueryNamesItsFolderAndFilterAsTheIndexReadsIt() {
        let home = "/synthetic/home"
        #expect(FolderBrowser.split("/", home: home)! == ("/", ""))
        #expect(FolderBrowser.split("/Applications/Saf", home: home)! == ("/Applications", "Saf"))
        #expect(FolderBrowser.split("~", home: home)! == (home, ""))
        #expect(FolderBrowser.split("~/Proj", home: home)! == (home, "Proj"))
        #expect(FolderBrowser.split("~Proj", home: home)! == (home, "Proj"))
        #expect(FolderBrowser.split("/a/../b/c", home: home)! == ("/b", "c"))
        #expect(FolderBrowser.split("notes", home: home) == nil)
    }
}
