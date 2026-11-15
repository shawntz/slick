import Foundation
import Kit
import KitTesting
import Testing

@testable import Bookmarks

/// The folder logic the live service uses, run on synthetic trees in a temporary folder. The live
/// service itself is never made in a test: it would read the real home folder.
@Suite("Browser folders", .timeLimit(.minutes(1)))
struct FolderTests {
    final class Tree {
        let root = Samples.temporaryFolder()

        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func file(_ path: String, _ contents: Data = Data("{}".utf8)) -> URL {
            let url = root.appending(path: path)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? contents.write(to: url)
            return url
        }

        func folder(_ path: String) {
            try? FileManager.default.createDirectory(at: root.appending(path: path), withIntermediateDirectories: true)
        }
    }

    @Test func chromiumProfilesAreFoundByFolderName() {
        let tree = Tree()
        tree.file("Chrome/Default/Bookmarks")
        tree.file("Chrome/Profile 10/Bookmarks")
        tree.file("Chrome/Profile 2/AccountBookmarks")
        tree.file("Chrome/Guest Profile/Bookmarks")
        tree.file("Chrome/System Profile/Bookmarks")
        tree.file("Chrome/Crashpad/Bookmarks")
        tree.folder("Chrome/Profile 3")
        tree.file("Chrome/Local State")
        let profiles = BrowserFolders.profiles(of: .chrome, in: tree.root.appending(path: "Chrome"))
        #expect(profiles.map(\.key) == ["Default", "Profile 2", "Profile 10"])
        #expect(profiles[0].files.map(\.lastPathComponent) == ["Bookmarks", "AccountBookmarks"])
    }

    @Test func operasOwnFolderIsAProfile() {
        let tree = Tree()
        tree.file("Opera/Bookmarks")
        let profiles = BrowserFolders.profiles(of: .opera, in: tree.root.appending(path: "Opera"))
        #expect(profiles.map(\.id) == ["opera"])
        #expect(profiles.map(\.name) == ["Opera"])
    }

    @Test func firefoxProfilesNeedADatabase() {
        let tree = Tree()
        tree.file("Profiles/ab12cd34.default-release/places.sqlite")
        tree.file("Profiles/ef56gh78.work/places.sqlite")
        tree.folder("Profiles/ij90kl12.empty")
        tree.file("Profiles/profiles.ini")
        let profiles = BrowserFolders.profiles(of: .firefox, in: tree.root.appending(path: "Profiles"))
        #expect(profiles.map(\.name) == ["default-release", "work"])
        #expect(
            BrowserFolders.stampedFiles(of: profiles[0]).map(\.lastPathComponent) == [
                "places.sqlite", "places.sqlite-wal",
            ])
    }

    @Test func aMissingFolderHasNoProfiles() {
        let tree = Tree()
        #expect(BrowserFolders.profiles(of: .brave, in: tree.root.appending(path: "Nothing Here")).isEmpty)
        #expect(BrowserFolders.profiles(of: .firefox, in: tree.root.appending(path: "Nothing Here")).isEmpty)
    }

    @Test func linkedProfilesAndFilesAreNotFollowed() throws {
        let tree = Tree()
        let outside = tree.file("Elsewhere/Bookmarks")
        tree.folder("Chrome")
        try FileManager.default.createSymbolicLink(
            at: tree.root.appending(path: "Chrome/Default"), withDestinationURL: outside.deletingLastPathComponent())
        tree.folder("Chrome/Profile 1")
        try FileManager.default.createSymbolicLink(
            at: tree.root.appending(path: "Chrome/Profile 1/Bookmarks"), withDestinationURL: outside)
        #expect(BrowserFolders.profiles(of: .chrome, in: tree.root.appending(path: "Chrome")).isEmpty)
        #expect(throws: BookmarkReadError.unreadable) {
            try BrowserFolders.read(tree.root.appending(path: "Chrome/Profile 1/Bookmarks"))
        }
    }

    @Test func onlyTheExpectedFilesInsideTheBrowsersFolderPass() {
        let folder = URL(filePath: "/synthetic/Chrome/")
        #expect(
            BrowserFolders.isExpected(
                URL(filePath: "/synthetic/Chrome/Default/Bookmarks"), browser: .chrome, in: folder))
        #expect(
            !BrowserFolders.isExpected(URL(filePath: "/synthetic/Chrome/Default/History"), browser: .chrome, in: folder)
        )
        #expect(!BrowserFolders.isExpected(URL(filePath: "/synthetic/Other/Bookmarks"), browser: .chrome, in: folder))
        #expect(
            !BrowserFolders.isExpected(
                URL(filePath: "/synthetic/Chrome/../Other/Bookmarks"), browser: .chrome, in: folder))
        #expect(!BrowserFolders.isExpected(URL(filePath: "/synthetic/ChromeX/Bookmarks"), browser: .chrome, in: folder))
        #expect(
            !BrowserFolders.isExpected(
                URL(filePath: "/synthetic/Chrome/Default/Bookmarks"), browser: .firefox, in: folder))
    }

    @Test func readingMissingLargeAndOrdinaryFiles() throws {
        let tree = Tree()
        #expect(try BrowserFolders.read(tree.root.appending(path: "missing")) == nil)
        let small = tree.file("small", Data("abc".utf8))
        #expect(try BrowserFolders.read(small) == Data("abc".utf8))
        #expect(throws: BookmarkReadError.tooLarge) { try BrowserFolders.read(small, limit: 2) }
        tree.folder("a folder")
        #expect(throws: BookmarkReadError.unreadable) { try BrowserFolders.read(tree.root.appending(path: "a folder")) }
    }

    @Test func stampsChangeWithTheFile() throws {
        let tree = Tree()
        let file = tree.file("Bookmarks", Data("one".utf8))
        let first = FileStamp.of([file, tree.root.appending(path: "missing")])
        #expect(first.parts.count == 1)
        try Data("two, longer".utf8).write(to: file)
        #expect(FileStamp.of([file]) != first)
    }

    @Test func everyRunOutsideTheAppGetsTheIsolatedService() {
        for environment in RunEnvironment.allCases where !environment.touchesRealSystem {
            let context = FakeServices().context(featureID: "bookmarks", environment: environment)
            #expect(context.service(BookmarkFileServiceKey.self) is IsolatedBookmarkFiles, "\(environment)")
        }
    }

    @Test func theIsolatedSampleHasEveryFormat() async throws {
        let files = IsolatedBookmarkFiles.sample(home: URL(filePath: "/synthetic-home"))
        var titles: [String] = []
        for browser in Browser.allCases {
            for profile in await files.profiles(of: browser) {
                for data in try await files.contents(of: profile) {
                    titles += try BookmarkLoader.parse(data, format: browser.format).map(\.title)
                }
            }
        }
        #expect(titles.contains("A Long Read About Maps"))
        #expect(titles.contains("Garden Planner"))
        #expect(titles.contains("Library Catalog"))
        #expect(!titles.contains(""))
    }
}
