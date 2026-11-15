import CoreServices
import Foundation
import Kit
import KitTesting
import Testing

@testable import Platform

/// What FSEvents reports, turned into Kit's events. Every path is synthetic.
@Suite(.timeLimit(.minutes(1))) struct FileChangeBatchingTests {
    static let paths = WatchedPaths(roots: [
        (requested: "/var/folders/xy/T/home", real: "/private/var/folders/xy/T/home"),
        (requested: "/Volumes/Stick", real: "/Volumes/Stick"),
    ])
    static let histories = ["/var/folders/xy/T/home": "HISTORY-A", "/Volumes/Stick": "HISTORY-B"]

    static func batcher(mark: FileChangeMark? = nil, current: UInt64 = 900) -> EventBatcher {
        let plan = ResumePlan(
            mark: mark, roots: paths.roots.map(\.requested), histories: histories, currentEventID: current)
        return EventBatcher(paths: paths, plan: plan, histories: histories, currentEventID: current)
    }

    static func raw(_ flags: Int...) -> UInt32 {
        UInt32(flags.reduce(0, |))
    }

    @Test func everyFSEventsFlagThatMattersHasAKitFlag() {
        let pairs: [(Int, FileChangeFlags)] = [
            (kFSEventStreamEventFlagMustScanSubDirs, .mustScanSubdirectories),
            (kFSEventStreamEventFlagUserDropped, .userDropped),
            (kFSEventStreamEventFlagKernelDropped, .kernelDropped),
            (kFSEventStreamEventFlagEventIdsWrapped, .eventIDsWrapped),
            (kFSEventStreamEventFlagHistoryDone, .historyDone),
            (kFSEventStreamEventFlagRootChanged, .rootChanged),
            (kFSEventStreamEventFlagMount, .mount),
            (kFSEventStreamEventFlagUnmount, .unmount),
            (kFSEventStreamEventFlagItemCreated, .created),
            (kFSEventStreamEventFlagItemRemoved, .removed),
            (kFSEventStreamEventFlagItemRenamed, .renamed),
            (kFSEventStreamEventFlagItemModified, .modified),
            (kFSEventStreamEventFlagItemXattrMod, .metadataModified),
            (kFSEventStreamEventFlagItemIsFile, .isFile),
            (kFSEventStreamEventFlagItemIsDir, .isDirectory),
            (kFSEventStreamEventFlagItemIsSymlink, .isSymlink),
        ]
        for (bit, flag) in pairs {
            #expect(EventBatcher.flags(fromFSEvents: UInt32(bit)) == flag, "\(bit)")
        }
        #expect(
            EventBatcher.flags(
                fromFSEvents: Self.raw(kFSEventStreamEventFlagItemCreated, kFSEventStreamEventFlagItemIsDir))
                == [.created, .isDirectory])
        #expect(FileChangeFlags.lostHistory.requiresRescan)
        #expect(FileChangeFlags.rootChanged.requiresRescan && FileChangeFlags.mount.requiresRescan)
        #expect(!FileChangeFlags([.created, .modified, .isFile]).requiresRescan)
    }

    @Test func anEventInsideAFolderKeepsItsFlagsIDAndTheCallersSpelling() throws {
        let batch = try #require(
            Self.batcher().batch(
                paths: ["/private/var/folders/xy/T/home/notes.md"],
                flags: [Self.raw(kFSEventStreamEventFlagItemCreated, kFSEventStreamEventFlagItemIsFile)], ids: [1001]))
        #expect(
            batch.events == [
                FileChange(URL(filePath: "/var/folders/xy/T/home/notes.md"), flags: [.created, .isFile], id: 1001)
            ])
        #expect(batch.mark == FileChangeMark(eventID: 1001, histories: Self.histories))
    }

    @Test func droppedEventsReportedForTheVolumeRootReachEveryFolder() throws {
        let dropped = Self.raw(kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagKernelDropped)
        let batch = try #require(Self.batcher().batch(paths: ["/"], flags: [dropped], ids: [1002]))
        #expect(batch.events.map(\.url.path) == ["/var/folders/xy/T/home", "/Volumes/Stick"])
        #expect(
            batch.events.allSatisfy {
                $0.flags == [.mustScanSubdirectories, .kernelDropped] && $0.flags.requiresRescan
            })
        // A coalesced rescan of a folder above only one of them reaches only that one.
        let above = try #require(
            Self.batcher().batch(
                paths: ["/private/var/folders"], flags: [Self.raw(kFSEventStreamEventFlagMustScanSubDirs)], ids: [1003])
        )
        #expect(above.events.map(\.url.path) == ["/var/folders/xy/T/home"])
        // Anything else outside the folders is dropped.
        #expect(
            Self.batcher().batch(
                paths: ["/private/var/folders/zz/other"], flags: [Self.raw(kFSEventStreamEventFlagItemCreated)],
                ids: [1004]) == nil)
    }

    @Test func aMovedFolderIsReportedAsARootChangeWithoutMovingTheMark() throws {
        let batcher = Self.batcher()
        _ = batcher.batch(paths: ["/Volumes/Stick/a"], flags: [0], ids: [1005])
        let batch = try #require(
            batcher.batch(paths: ["/Volumes/Stick"], flags: [Self.raw(kFSEventStreamEventFlagRootChanged)], ids: [0]))
        #expect(batch.events == [FileChange(URL(filePath: "/Volumes/Stick"), flags: .rootChanged, id: 0)])
        #expect(batch.mark?.eventID == 1005)
    }

    @Test func aMatchingHistoryIsReplayedAndEndsWithHistoryDoneOncePerFolder() throws {
        let mark = FileChangeMark(eventID: 500, histories: Self.histories)
        let plan = ResumePlan(
            mark: mark, roots: Self.paths.roots.map(\.requested), histories: Self.histories, currentEventID: 900)
        #expect(plan.sinceWhen == 500)
        #expect(plan.lostRoots.isEmpty)
        let batcher = Self.batcher(mark: mark)
        #expect(batcher.lostHistoryBatch() == nil)
        let replayed = try #require(batcher.batch(paths: ["/Volumes/Stick/b"], flags: [0], ids: [600]))
        #expect(replayed.mark?.eventID == 600)
        let done = try #require(
            batcher.batch(paths: [""], flags: [Self.raw(kFSEventStreamEventFlagHistoryDone)], ids: [601]))
        #expect(done.events.map(\.url.path) == ["/var/folders/xy/T/home", "/Volumes/Stick"])
        #expect(done.events.allSatisfy { $0.flags == .historyDone })
        #expect(batcher.batch(paths: [""], flags: [Self.raw(kFSEventStreamEventFlagHistoryDone)], ids: [602]) == nil)
    }

    @Test func aFolderWhoseHistoryChangedIsReadAgainInstead() throws {
        var then = Self.histories
        then["/Volumes/Stick"] = "HISTORY-OLD"
        let mark = FileChangeMark(eventID: 500, histories: then)
        let plan = ResumePlan(
            mark: mark, roots: Self.paths.roots.map(\.requested), histories: Self.histories, currentEventID: 900)
        #expect(plan.sinceWhen == 500)
        #expect(plan.replayingRoots == ["/var/folders/xy/T/home"])
        #expect(plan.lostRoots == ["/Volumes/Stick"])
        let lost = try #require(Self.batcher(mark: mark).lostHistoryBatch())
        #expect(lost.events == [FileChange(URL(filePath: "/Volumes/Stick"), flags: .lostHistory)])
        #expect(lost.mark?.eventID == 500)
    }

    @Test func aMarkPastTheNewestEventOrWithoutHistoryReplaysNothing() throws {
        let future = FileChangeMark(eventID: 5_000, histories: Self.histories)
        let plan = ResumePlan(
            mark: future, roots: Self.paths.roots.map(\.requested), histories: Self.histories, currentEventID: 900)
        #expect(plan.sinceWhen == nil)
        #expect(plan.lostRoots.count == 2)
        // Starting fresh, the mark starts at the newest event, never at zero.
        let lost = try #require(Self.batcher(mark: future).lostHistoryBatch())
        #expect(lost.mark?.eventID == 900)
        let none = ResumePlan(
            mark: FileChangeMark(eventID: 10, histories: [:]), roots: ["/a"], histories: ["/a": "H"],
            currentEventID: 900
        )
        #expect(none.sinceWhen == nil && none.lostRoots == ["/a"])
        let fresh = ResumePlan(mark: nil, roots: ["/a"], histories: ["/a": "H"], currentEventID: 900)
        #expect(fresh.sinceWhen == nil && fresh.lostRoots.isEmpty && fresh.replayingRoots.isEmpty)
    }

    @Test func aWatchWithoutAnyHistoryGivesNoMark() throws {
        let plan = ResumePlan(mark: nil, roots: ["/Volumes/Share"], histories: [:], currentEventID: 900)
        let paths = WatchedPaths(roots: [(requested: "/Volumes/Share", real: "/Volumes/Share")])
        let batcher = EventBatcher(paths: paths, plan: plan, histories: [:], currentEventID: 900)
        let batch = try #require(batcher.batch(paths: ["/Volumes/Share/x"], flags: [0], ids: [901]))
        #expect(batch.mark == nil)
    }
}

/// The live watcher on a fresh temporary folder. FSEvents may start a moment after the call
/// returns, so writes repeat until the change is seen.
@Suite(.timeLimit(.minutes(1))) struct LiveFileChangeTests {
    /// The first batch from `events` that `matches` accepts, while `write` runs over and over.
    func firstBatch(
        of events: AsyncStream<FileChangeBatch>, write: @escaping @Sendable (Int) -> Void,
        where matches: @escaping @Sendable (FileChangeBatch) -> Bool
    ) async -> FileChangeBatch? {
        let reported = Task {
            for await batch in events where matches(batch) { return Optional(batch) }
            return nil
        }
        let writer = Task {
            for attempt in 0..<50 where !Task.isCancelled {
                write(attempt)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { writer.cancel() }
        return await boundedValue(of: reported)
    }

    @Test func aNewFileComesWithFlagsAnIDAndAMark() async throws {
        let folder = TemporaryFolder()
        let watcher = FSEventsWatcher(latency: .milliseconds(50))
        let events = watcher.watchChanges([folder.url], since: nil)
        let file = folder.url.appending(path: "notes.txt")
        let batch = try #require(
            await firstBatch(
                of: events, write: { try? Data("attempt \($0)".utf8).write(to: file) },
                where: { batch in batch.events.contains { $0.url.lastPathComponent == "notes.txt" } }))
        let event = try #require(batch.events.first { $0.url.lastPathComponent == "notes.txt" })
        #expect(event.url.path(percentEncoded: false).hasPrefix(folder.url.path(percentEncoded: false)))
        #expect(event.flags.contains(.isFile))
        #expect(event.id > 0)
        let mark = try #require(batch.mark)
        #expect(mark.eventID >= event.id)
        #expect(mark.histories.keys.contains(WatchedPaths([folder.url]).roots[0].requested))
        withExtendedLifetime(folder) {}
    }

    @Test func aMarkReplaysWhatChangedWhileNobodyWatched() async throws {
        let folder = TemporaryFolder()
        let watcher = FSEventsWatcher(latency: .milliseconds(50))
        let first = folder.url.appending(path: "first.txt")
        let firstBatch = try #require(
            await firstBatch(
                of: watcher.watchChanges([folder.url], since: nil), write: { try? Data("\($0)".utf8).write(to: first) },
                where: { batch in batch.events.contains { $0.url.lastPathComponent == "first.txt" } }))
        try await waitUntil { watcher.openStreamCount == 0 }
        let mark = try #require(firstBatch.mark)
        try Data("while away".utf8).write(to: folder.url.appending(path: "later.txt"))
        let resumed = watcher.watchChanges([folder.url], since: mark)
        // A change from the moment before the watch started may not be in the history yet. It then
        // arrives live, right after the history ends, so the test waits for both.
        let collected = Task {
            var names: [String] = []
            for await batch in resumed {
                names += batch.events.map { $0.flags.contains(.historyDone) ? "<done>" : $0.url.lastPathComponent }
                if names.contains("<done>"), names.contains("later.txt") { return names }
            }
            return names
        }
        let names = await boundedValue(of: collected)
        #expect(names.filter { $0 == "<done>" }.count == 1)
        #expect(names.contains("later.txt"))
        withExtendedLifetime(folder) {}
    }

    @Test func movingTheWatchedFolderIsARootChange() async throws {
        let parent = TemporaryFolder()
        let watched = parent.url.appending(path: "watched", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        let watcher = FSEventsWatcher(latency: .milliseconds(50))
        let events = watcher.watchChanges([watched], since: nil)
        let moved = parent.url.appending(path: "moved", directoryHint: .isDirectory)
        let batch = await firstBatch(
            of: events,
            write: { attempt in
                // Moves the folder away and back, so each attempt is a change along the root.
                let (from, to) = attempt.isMultiple(of: 2) ? (watched, moved) : (moved, watched)
                try? FileManager.default.moveItem(at: from, to: to)
            },
            where: { batch in batch.events.contains { $0.flags.contains(.rootChanged) } })
        let change = try #require(batch?.events.first { $0.flags.contains(.rootChanged) })
        #expect(change.url.lastPathComponent == "watched")
        #expect(change.flags.requiresRescan)
        withExtendedLifetime(parent) {}
    }

    @Test func watchingNothingEndsAtOnce() async {
        let watcher = FSEventsWatcher()
        var iterator = watcher.watchChanges([], since: nil).makeAsyncIterator()
        #expect(await iterator.next() == nil)
        #expect(watcher.openStreamCount == 0)
    }
}

/// Kit's fake and Kit's default for watchers that keep no history.
@Suite(.timeLimit(.minutes(1))) struct FakeFileChangeTests {
    @Test func aDeletedFileUnderPrivateStillMatchesItsFolder() async throws {
        let watcher = FakeFileWatcher()
        let folder = URL(filePath: "/var/folders/synthetic-\(UUID().uuidString)/T/tree", directoryHint: .isDirectory)
        var paths = watcher.watch([folder]).makeAsyncIterator()
        var events = watcher.watchChanges([folder], since: nil).makeAsyncIterator()
        let gone = URL(filePath: "/private" + folder.path(percentEncoded: false) + "gone.txt")
        watcher.simulateChange([gone])
        #expect(await paths.next() == [gone])
        let batch = try #require(await events.next())
        #expect(
            batch.events.map { $0.url.path(percentEncoded: false) } == [folder.path(percentEncoded: false) + "gone.txt"]
        )
        // A sibling whose name only starts with the folder's is not inside it.
        watcher.simulateChange([URL(filePath: String(folder.path(percentEncoded: false).dropLast()) + "-other/x")])
        watcher.simulateChange([folder.appending(path: "kept.txt")])
        #expect(await paths.next()?.map(\.lastPathComponent) == ["kept.txt"])
    }

    @Test func aRescanAboveTheFoldersReachesEachOneWithTheMark() async throws {
        let watcher = FakeFileWatcher()
        let home = URL(filePath: "/synthetic/home", directoryHint: .isDirectory)
        let stick = URL(filePath: "/Volumes/Stick", directoryHint: .isDirectory)
        let saved = FileChangeMark(eventID: 40, histories: ["/synthetic/home": "H"])
        var events = watcher.watchChanges([home, stick], since: saved).makeAsyncIterator()
        var paths = watcher.watch([home]).makeAsyncIterator()
        #expect(watcher.requestedMarks == [saved])
        let mark = FileChangeMark(eventID: 41, histories: ["/synthetic/home": "H"])
        watcher.simulateEvents(
            [FileChange(URL(filePath: "/"), flags: [.mustScanSubdirectories, .userDropped], id: 41)], mark: mark)
        let batch = try #require(await events.next())
        #expect(batch.events.map(\.url) == [home, stick])
        #expect(batch.events.allSatisfy { $0.flags == [.mustScanSubdirectories, .userDropped] && $0.id == 41 })
        #expect(batch.mark == mark)
        #expect(await paths.next() == [home])
    }

    /// A watcher that implements only the first form.
    struct PathsOnlyWatcher: FileWatchService {
        let fake = FakeFileWatcher()
        func watch(_ directories: [URL]) -> AsyncStream<[URL]> { fake.watch(directories) }
    }

    @Test func aWatcherWithoutHistoryAsksForARescanWhenAskedToResume() async throws {
        let watcher = PathsOnlyWatcher()
        let folder = URL(filePath: "/synthetic/scripts", directoryHint: .isDirectory)
        var resumed = watcher.watchChanges([folder], since: FileChangeMark(eventID: 7, histories: [:]))
            .makeAsyncIterator()
        let first = try #require(await resumed.next())
        #expect(first.events == [FileChange(folder, flags: .lostHistory)])
        #expect(first.mark == nil)
        try await waitUntil { !watcher.fake.watchedDirectories.isEmpty }
        watcher.fake.simulateChange([folder.appending(path: "run.sh")])
        let next = try #require(await resumed.next())
        #expect(next.events.map(\.url.lastPathComponent) == ["run.sh"])
        #expect(next.events.allSatisfy { $0.flags.isEmpty && $0.id == 0 })
    }
}
