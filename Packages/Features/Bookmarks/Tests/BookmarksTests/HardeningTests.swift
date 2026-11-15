import Foundation
import Kit
import KitTesting
import Testing

@testable import Bookmarks

/// Cases a second review found: a clock set back, and a private copy of Firefox's history left
/// behind by a read that never finished.
@MainActor
@Suite("Hardening", .timeLimit(.minutes(1)))
struct HardeningTests {
    static let profile = "ab12cd34.default-release"

    @Test func aClockSetBackStillReadsFirefoxChanges() async throws {
        let bookmarks = BookmarksHarness(files: ChoosingTests.sampleFiles)
        await bookmarks.harness.activate()
        try await bookmarks.choose(.firefox)
        try await bookmarks.open()
        #expect(bookmarks.files.reads == ["firefox/" + Self.profile])

        // The clock goes back a day, as when the user corrects it, then Firefox saves a bookmark.
        let clock = bookmarks.fakes.clock
        clock.set(clock.now.addingTimeInterval(-86_400))
        bookmarks.files.set(
            .firefox, profile: Self.profile,
            contents: [BookmarkFixtures.firefox(menu: [.link("New One", "https://new.example.com/")])])
        bookmarks.fakes.fileWatcher.simulateChange([bookmarks.file(.firefox, profile: Self.profile)])
        try await bookmarks.harness.settle()
        #expect(bookmarks.files.reads.count == 2, "a read in the clock's future counts as old")
        #expect(bookmarks.harness.rows.map(\.title) == ["New One"])
    }

    @Test func theFirefoxWaitFollowsTheClockBothWays() {
        let read = Date(timeIntervalSince1970: 1_000_000)
        #expect(BookmarkLoader.firefoxWait(since: read, now: read.addingTimeInterval(4)) == .seconds(6))
        #expect(BookmarkLoader.firefoxWait(since: read, now: read.addingTimeInterval(10)) == nil)
        #expect(BookmarkLoader.firefoxWait(since: read, now: read.addingTimeInterval(3_600)) == nil)
        #expect(BookmarkLoader.firefoxWait(since: read, now: read.addingTimeInterval(-1)) == nil)
        #expect(BookmarkLoader.firefoxWait(since: read, now: read.addingTimeInterval(-86_400 * 30)) == nil)
    }

    @Test func aCopyLeftByAnEarlierReadIsDeletedAndNothingElse() throws {
        let running = try FirefoxCopyTests.RunningDatabase()
        try running.add(1, title: "First")
        let scratch = Samples.temporaryFolder()
        let outside = Samples.temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: scratch)
            try? FileManager.default.removeItem(at: outside)
        }
        let manager = FileManager.default
        // What a read that crashed leaves: a private folder with a copy of the whole database.
        let leftover = scratch.appending(path: PrivateCopy.folderPrefix + "LEFTOVER", directoryHint: .isDirectory)
        try manager.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("history".utf8).write(to: leftover.appending(path: "places.sqlite"))
        // Things that are not the feature's copies stay: a file with the prefix, a link with the
        // prefix and the folder it points at, and an unrelated folder.
        let keptFile = scratch.appending(path: PrivateCopy.folderPrefix + "note.txt")
        try Data("keep".utf8).write(to: keptFile)
        try Data("keep".utf8).write(to: outside.appending(path: "places.sqlite"))
        let link = scratch.appending(path: PrivateCopy.folderPrefix + "link")
        try manager.createSymbolicLink(at: link, withDestinationURL: outside)
        let other = scratch.appending(path: "thumbnails", directoryHint: .isDirectory)
        try manager.createDirectory(at: other, withIntermediateDirectories: true)

        let image = try PrivateCopy.firefoxBookmarkImage(of: running.url, scratchRoot: scratch)
        #expect(try FirefoxPlaces.parse(image).map(\.title) == ["First"])

        let names = Set(try manager.contentsOfDirectory(atPath: scratch.path(percentEncoded: false)))
        #expect(names == [keptFile.lastPathComponent, link.lastPathComponent, "thumbnails"])
        #expect(manager.fileExists(atPath: outside.appending(path: "places.sqlite").path(percentEncoded: false)))
    }

    @Test func concurrentCopiesNeverDeleteEachOthersFolder() async throws {
        let running = try FirefoxCopyTests.RunningDatabase()
        try running.add(1, title: "First")
        try running.add(2, title: "Second")
        let scratch = Samples.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let url = running.url
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    guard let image = try? PrivateCopy.firefoxBookmarkImage(of: url, scratchRoot: scratch),
                        let parsed = try? FirefoxPlaces.parse(image)
                    else { return false }
                    return parsed.count == 2
                }
            }
            var all: [Bool] = []
            for await result in group { all.append(result) }
            return all
        }
        #expect(results == Array(repeating: true, count: 8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path(percentEncoded: false)).isEmpty)
    }
}
