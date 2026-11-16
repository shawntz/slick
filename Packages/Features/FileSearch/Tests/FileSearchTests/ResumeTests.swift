import CoreBridge
import Foundation
import Kit
import KitTesting
import Testing

@testable import FileSearch

@Suite("Resuming, stopping and following changes", .timeLimit(.minutes(1)))
@MainActor
struct ResumeTests {
    private func mark(_ id: UInt64, _ tree: TestTree) -> FileChangeMark {
        FileChangeMark(eventID: id, histories: [tree.home: "volume-1"])
    }

    @Test func aSavedIndexResumesFromItsMarkWithoutWalkingAgain() async throws {
        let tree = try TestTree()
        let first = try Fixture(tree: tree)
        try await first.start()
        #expect(first.fakes.fileWatcher.requestedMarks == [nil], "the first start has no mark")
        try tree.write("seen-live.txt")
        first.fakes.fileWatcher.simulateEvents(
            [FileChange(tree.url("seen-live.txt"), flags: [.created, .isFile], id: 500)], mark: mark(500, tree))
        try await first.idle()
        #expect(first.feature.controller.mark == mark(500, tree))
        await first.harness.deactivate()
        #expect(first.maker.savedMarks.last == mark(500, tree), "the index is saved with the mark it holds")
        #expect(DiskIndexMaker().savedMark(for: tree.indexFile) == mark(500, tree))

        try tree.write("while-off.txt")
        let second = try Fixture(tree: tree)
        try await second.start()
        #expect(second.fakes.fileWatcher.requestedMarks == [mark(500, tree)])
        #expect(second.maker.opens == 1 && second.maker.walks == 0, "the saved index is used as it is")
        #expect(try await second.rootPaths("seen-live") == ["seen-live.txt"])
        // The watcher replays what changed while the feature was off, then says the replay ended.
        second.fakes.fileWatcher.simulateEvents(
            [
                FileChange(tree.url("while-off.txt"), flags: [.created, .isFile], id: 511),
                FileChange(URL(filePath: tree.home), flags: .historyDone, id: 512),
            ], mark: mark(512, tree))
        try await second.idle()
        #expect(try await second.rootPaths("while-off") == ["while-off.txt"])
        #expect(second.maker.walks == 0)
        #expect(second.appliedPaths == ["while-off.txt"], "the end of the replay changes nothing")
        #expect(second.feature.controller.mark == mark(512, tree))
        withExtendedLifetime(first) {}
    }

    @Test func aMarkTheIndexFileDoesNotMatchIsNotTrusted() async throws {
        let tree = try TestTree()
        let first = try Fixture(tree: tree)
        try await first.start()
        first.fakes.fileWatcher.simulateEvents([FileChange(tree.url("notes.md"), id: 40)], mark: mark(40, tree))
        try await first.idle()
        await first.harness.deactivate()
        // A mark from another save: the index file says 40.
        try JSONEncoder().encode(mark(90, tree)).write(to: URL(filePath: DiskIndexMaker.markFile(for: tree.indexFile)))

        try tree.write("while-off.txt")
        let second = try Fixture(tree: tree)
        try await second.start()
        #expect(second.maker.rebuilds == 1, "the saved index is walked again")
        #expect(try await second.rootPaths("while-off") == ["while-off.txt"])
        withExtendedLifetime(first) {}
    }

    @Test func wrappedEventIDsDropTheSavedMark() async throws {
        let tree = try TestTree()
        let first = try Fixture(tree: tree)
        try await first.start()
        first.fakes.fileWatcher.simulateEvents([FileChange(tree.url("notes.md"), id: 70)], mark: mark(70, tree))
        try await first.idle()
        #expect(first.feature.controller.mark != nil)
        first.fakes.fileWatcher.simulateEvents([
            FileChange(URL(filePath: tree.home), flags: [.eventIDsWrapped, .mustScanSubdirectories])
        ])
        try await first.idle()
        #expect(first.feature.controller.mark == nil)
        await first.harness.deactivate()
        #expect(first.maker.savedMarks.last == .some(nil))
        #expect(DiskIndexMaker().savedMark(for: tree.indexFile) == nil)

        let second = try Fixture(tree: tree)
        try await second.start()
        #expect(second.fakes.fileWatcher.requestedMarks == [nil])
        #expect(second.maker.rebuilds == 1, "without a mark the saved index is walked again")
        withExtendedLifetime(first) {}
    }

    @Test func aStoppedBatchKeepsTheMarkAndAFailedOneDropsIt() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        let tree = fixture.tree
        fixture.fakes.fileWatcher.simulateEvents([FileChange(tree.url("notes.md"), id: 10)], mark: mark(10, tree))
        try await fixture.idle()
        #expect(fixture.feature.controller.mark == mark(10, tree))
        // Stopped by the close: it changed nothing, so the next start replays it from the mark.
        fixture.maker.failNextApply(with: .cancelled)
        fixture.fakes.fileWatcher.simulateEvents([FileChange(tree.url("beach.jpg"), id: 20)], mark: mark(20, tree))
        try await fixture.idle()
        #expect(fixture.feature.controller.mark == mark(10, tree))
        // Failed: the index may miss it, so no mark is kept.
        fixture.maker.failNextApply(with: .io)
        fixture.fakes.fileWatcher.simulateEvents([FileChange(tree.url("beach.jpg"), id: 30)], mark: mark(30, tree))
        try await fixture.idle()
        #expect(fixture.feature.controller.mark == nil)
        await fixture.harness.deactivate()
        #expect(fixture.maker.savedMarks.last == .some(nil))
    }

    @Test func aFolderWhoseHistoryIsLostIsReadAgainWhole() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        try fixture.tree.write("Projects/app/src/deep/missed.swift")
        fixture.fakes.fileWatcher.simulateEvents([
            FileChange(URL(filePath: fixture.tree.home), flags: .lostHistory)
        ])
        try await fixture.idle()
        let flags = try #require(fixture.maker.batches.last?.first?.flags)
        #expect(flags & IndexController.mustScanSubDirs != 0)
        #expect(try await fixture.rootPaths("missed") == ["Projects/app/src/deep/missed.swift"])
    }

    @Test func changeFlagsBecomeTheBitsTheIndexReads() {
        #expect(IndexController.eventFlags([], rescans: false) == 0)
        #expect(IndexController.eventFlags([], rescans: true) == IndexController.mustScanSubDirs, "a bare root")
        #expect(IndexController.eventFlags([.created, .isFile], rescans: false) == 0x0001_0100)
        #expect(IndexController.eventFlags([.modified], rescans: true) == 0x0000_1000, "a root that only changed")
        for rescan: FileChangeFlags in [.rootChanged, .mount, .unmount, .mustScanSubdirectories] {
            #expect(IndexController.eventFlags(rescan, rescans: false) & IndexController.mustScanSubDirs != 0)
        }
        #expect(IndexController.eventFlags(.lostHistory, rescans: false) == 0x0000_0011)
    }

    @Test func turningTheFeatureOffStopsAWalk() async throws {
        let fixture = try Fixture()
        fixture.maker.holdNextBuild()
        await fixture.harness.activate()
        await fixture.maker.waitForHeldBuild()
        await fixture.harness.deactivate()
        #expect(fixture.maker.stoppedWalks == 1)
        #expect(fixture.maker.saves == 0, "a stopped walk publishes and saves nothing")
        #expect(fixture.feature.controller.summary.phase == .idle)
        #expect(fixture.feature.status == nil, "stopping is not a failure")
        // Back on, the next walk runs to its end.
        try await fixture.start()
        #expect(try await fixture.rootPaths("notes") == ["notes.md"])
        await fixture.harness.deactivate()
    }

    @Test func aWatchThatEndsByItselfIsReportedAndRebuildWatchesAgain() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        let declarations = fixture.feature.declarations.stream()
        fixture.feature.follow(AsyncStream { $0.finish() }, roots: fixture.feature.watchedRoots)
        for await _ in declarations where fixture.feature.watchStopped { break }
        #expect(fixture.feature.status?.title == "Not Following File Changes")
        #expect(fixture.feature.status?.level == .warning)
        try await fixture.harness.run("rebuild")
        try await fixture.idle()
        #expect(!fixture.feature.watchStopped)
        #expect(fixture.feature.status == nil)
        #expect(fixture.fakes.fileWatcher.watchedDirectories.count == 1)
        try fixture.tree.write("after-restart.txt")
        fixture.fakes.fileWatcher.simulateEvents([FileChange(fixture.tree.url("after-restart.txt"), flags: .created)])
        try await fixture.idle()
        #expect(try await fixture.rootPaths("after-restart") == ["after-restart.txt"])
    }
}
