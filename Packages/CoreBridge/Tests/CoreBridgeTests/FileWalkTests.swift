import Foundation
import SlickCoreC
import Testing

@testable import CoreBridge

/// A synthetic tree of 1 + 20 + 20 × 40 = 821 folders, each leaf with one file.
private func largeTree() throws -> (SyntheticTree, folders: Int) {
    let tree = try SyntheticTree()
    for group in 0..<20 {
        for leaf in 0..<40 {
            try tree.file("bulk/g\(group)/l\(leaf)/item.txt", size: 1)
        }
    }
    return (tree, 1 + 20 + 20 * 40)
}

private func bulkConfiguration(_ tree: SyntheticTree) -> FileIndexConfiguration {
    FileIndexConfiguration(roots: [tree.path("bulk")], home: tree.root.path, walkerThreads: 2)
}

@Suite("Cancelled walks, nested roots and folders listed from disk", .timeLimit(.minutes(2)))
struct FileWalkTests {
    @Test func aCancelledBuildThrowsCancelledAndAResetFlagLetsItFinish() throws {
        let (tree, folders) = try largeTree()
        defer { tree.remove() }
        let flag = try FileWalkCancellation()
        // Stopped at the 51st of 821 folders: the build returns there, without an index.
        flag.cancel(afterFolders: 50)
        #expect(throws: CoreError.cancelled) { try FileIndex.build(bulkConfiguration(tree), cancellation: flag) }
        #expect(flag.isCancelled)
        // Still set, it stops the next build before the first folder.
        #expect(throws: CoreError.cancelled) { try FileIndex.build(bulkConfiguration(tree), cancellation: flag) }
        flag.reset()
        #expect(!flag.isCancelled)
        let (index, walk) = try FileIndex.build(bulkConfiguration(tree), cancellation: flag)
        #expect(walk.folders == folders)
        #expect(try index.count() == folders + 20 * 40)
    }

    @Test func aCancelledRebuildOrBatchKeepsTheSnapshot() throws {
        let (tree, _) = try largeTree()
        defer { tree.remove() }
        let flag = try FileWalkCancellation()
        let index = try FileIndex.build(bulkConfiguration(tree), cancellation: flag).index
        let before = try index.count()
        let generation = try index.snapshot().info.generation
        try tree.file("bulk/g0/l0/new.txt", size: 1)
        flag.cancel(afterFolders: 10)
        #expect(throws: CoreError.cancelled) { try index.rebuild(cancellation: flag) }
        #expect(try index.count() == before)
        #expect(try index.snapshot().info.generation == generation, "nothing was published")

        let rescan = [FileEvent(path: tree.path("bulk"), flags: 1)]
        flag.reset()
        flag.cancel(afterFolders: 10)
        #expect(throws: CoreError.cancelled) { try index.apply(rescan, cancellation: flag) }
        #expect(try index.count() == before)
        flag.reset()
        let stats = try index.apply(rescan, cancellation: flag)
        #expect(stats.added == 1)
        #expect(try index.count() == before + 1)
    }

    @Test func openingASavedFileIsNeverInterrupted() throws {
        let (tree, _) = try largeTree()
        defer { tree.remove() }
        let file = tree.path("index.bin")
        let index = try FileIndex.build(bulkConfiguration(tree)).index
        try index.save(to: file, eventID: 9)
        let flag = try FileWalkCancellation()
        flag.cancel()
        let (opened, info) = try FileIndex.openOrBuild(at: file, bulkConfiguration(tree), cancellation: flag)
        #expect(info.opened && info.eventID == 9)
        #expect(try opened.count() == index.count())
        var other = bulkConfiguration(tree)
        other.includeHidden = true
        #expect(throws: CoreError.cancelled, "other rules refuse the file, and the build stops") {
            try FileIndex.openOrBuild(at: file, other, cancellation: flag)
        }
    }

    @Test func aRootInsideTheSkippedLibraryFolderIsKeptWhenAsked() throws {
        let tree = try SyntheticTree()
        defer { tree.remove() }
        try tree.file("Library/Mobile Documents/drive/plan.md", size: 3)
        let session = try FileSearchSession(capacity: 10)
        for keeps in [false, true] {
            let configuration = FileIndexConfiguration(
                roots: [tree.root.path, tree.path("Library/Mobile Documents")], home: tree.root.path,
                keepsRootsInSkippedFolders: keeps)
            let index = try FileIndex.build(configuration).index
            session.reset()
            try session.search("plan", in: index)
            #expect(relativePaths(session, tree) == (keeps ? ["Library/Mobile Documents/drive/plan.md"] : []))
            session.reset()
            try session.search("cache", in: index)
            #expect(session.count == 0, "the rest of Library stays skipped")
        }
    }

    @Test func aFolderIsListedFromDiskWithTheRules() throws {
        let tree = try SyntheticTree()
        defer { tree.remove() }
        let listing = try FileIndex.listFolder(tree.root.path, rules: tree.configuration)
        #expect(listing.problem == nil && listing.complete)
        #expect(listing.items.map(\.name) == ["Tool.app", "café", "docs", "photos", "projects"])
        #expect(listing.items[0].flags == [.directory, .package])
        #expect(listing.items[0].size == nil)
        let docs = try FileIndex.listFolder(tree.path("docs"), rules: tree.configuration)
        #expect(docs.items.first { $0.name == "report 2024.pdf" }?.size == 4_000)

        #expect(try FileIndex.listFolder(tree.path("missing"), rules: tree.configuration).problem == .missing)
        #expect(try FileIndex.listFolder(tree.path("docs/readme.md"), rules: tree.configuration).problem == .notAFolder)
        #expect(throws: CoreError.invalidArgument) { try FileIndex.listFolder("docs", rules: tree.configuration) }
        #expect(throws: CoreError.invalidArgument) { try FileIndex.listFolder("", rules: tree.configuration) }
    }

    @Test func aLargeFolderGrowsTheBuffers() throws {
        let tree = try SyntheticTree()
        defer { tree.remove() }
        let names = (0..<300).map { String(format: "entry-%03d-with-a-longer-generic-name.txt", $0) }
        for name in names {
            try tree.file("many/\(name)", size: 1)
        }
        let listing = try FileIndex.listFolder(tree.path("many"), rules: tree.configuration)
        #expect(listing.items.map(\.name) == names)
    }

    /// Foundation's file URLs and older volumes store names decomposed: a base letter and its
    /// combining marks. Such a name ranks and highlights like the same name composed.
    @Test func aDecomposedNameMatchesLikeAComposedOne() throws {
        let tree = try SyntheticTree()
        defer { tree.remove() }
        // POSIX writes the bytes as given, so the first name stays decomposed on disk.
        let decomposed = "cre\u{0300}me plan.txt"
        #expect(decomposed.unicodeScalars.count == 15)
        try tree.file("nfd/\(decomposed)", size: 1)
        try tree.file("nfc/crème plan.txt", size: 1)
        let index = try FileIndex.build(tree.configuration).index
        let session = try FileSearchSession(capacity: 10)
        try session.search("creme plan", in: index)
        #expect(session.count == 2)
        var ranges: [[HighlightRange]] = []
        for i in 0..<session.count {
            #expect(session[i].tier == session[0].tier, "the same tier both ways")
            ranges.append(try session.highlightRanges(for: session[i]))
        }
        let byFolder = Dictionary(
            uniqueKeysWithValues: (0..<session.count).map {
                (relativePaths(session, tree)[$0].hasPrefix("nfd") ? "nfd" : "nfc", ranges[$0])
            })
        // The whole text matches at the start, so each name gets one range; the decomposed one is a
        // unit longer because it covers the combining mark.
        #expect(byFolder["nfd"]?.map(\.location) == [0])
        #expect(byFolder["nfd"]?.map(\.length) == [11])
        #expect(byFolder["nfc"]?.map(\.location) == [0])
        #expect(byFolder["nfc"]?.map(\.length) == [10])
    }

    @Test func theCancelledStatusHasItsOwnError() {
        #expect(SLICK_STATUS_CANCELLED.rawValue == -8)
        #expect(throws: CoreError.cancelled) { try CoreError.check(-8) }
    }
}
