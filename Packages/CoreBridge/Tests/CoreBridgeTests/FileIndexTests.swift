import Foundation
import SlickCoreC
import Synchronization
import Testing

@testable import CoreBridge

/// A synthetic folder tree under the system temporary folder, never the home folder. Removed by
/// `remove()`.
struct SyntheticTree {
    static let counter = Atomic<Int>(0)
    let root: URL

    init() throws {
        // The index stores real paths, and the temporary folder sits behind the /var symlink.
        let temporary = FileManager.default.temporaryDirectory.path
        let real = realpath(temporary, nil)
        defer { free(real) }
        let base = URL(fileURLWithPath: real.map { String(cString: $0) } ?? temporary, isDirectory: true)
        // Digits only, so the root's own name matches no test query.
        let n = SyntheticTree.counter.add(1, ordering: .relaxed).newValue
        root = base.appendingPathComponent("cb\(ProcessInfo.processInfo.processIdentifier)0\(n)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, size) in [
            ("docs/readme.md", 120),
            ("docs/report 2024.pdf", 4_000),
            ("docs/Meeting Notes.txt", 10),
            ("projects/app/src/main.rs", 300),
            ("projects/app/README.md", 50),
            ("photos/beach.jpg", 9_000),
            ("café/crème brûlée.txt", 5),
            (".hidden/secret.txt", 1),
            ("node_modules/pkg/index.js", 1),
            ("Library/cache.db", 1),
            ("Tool.app/Contents/Info.plist", 1),
        ] {
            try file(path, size: size)
        }
    }

    /// Writes a file of `size` bytes. The name goes to the file system byte for byte through
    /// POSIX calls: Foundation's file URLs would store it decomposed.
    @discardableResult
    func file(_ path: String, size: Int) throws -> String {
        let full = root.path + "/" + path
        let parts = path.split(separator: "/").dropLast()
        var built = root.path
        for part in parts {
            built += "/" + part
            _ = mkdir(built, 0o755)
        }
        let fd = open(full, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        let bytes = [UInt8](repeating: 0x78, count: size)
        guard bytes.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == size else {
            throw CocoaError(.fileWriteUnknown)
        }
        return full
    }

    func path(_ relative: String) -> String { root.path + "/" + relative }

    var configuration: FileIndexConfiguration {
        FileIndexConfiguration(roots: [root.path], home: root.path)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// Paths of the session's hits relative to the tree.
func relativePaths(_ session: FileSearchSession, _ tree: SyntheticTree) -> [String] {
    (0..<session.count).compactMap { session.path(of: session[$0].id) }
        .map { String($0.dropFirst(tree.root.path.count + 1)) }
}

@Suite("File index", .timeLimit(.minutes(2)))
struct FileIndexTests {
    @Test func theSwiftValuesMatchTheHeader() {
        #expect(FileEntryFlags.directory.rawValue == UInt8(SLICK_FILES_ENTRY_DIR))
        #expect(FileEntryFlags.unreadable.rawValue == UInt8(SLICK_FILES_ENTRY_UNREADABLE))
        #expect(FileMatch.browse.rawValue == UInt8(SLICK_FILES_HOW_BROWSE))
        #expect(FileIndexLoadError.mismatch.rawValue == UInt8(SLICK_FILES_LOAD_MISMATCH))
        #expect(FileSearchOptions.Kinds.folders.rawValue == UInt8(SLICK_FILES_KINDS_FOLDERS))
        #expect(FileSearchOptions.BrowseOrder.modified.rawValue == UInt8(SLICK_FILES_SORT_MODIFIED))
        #expect(MemoryLayout<SlickFileHit>.size == 12)
    }

    @Test func buildSearchResolveHighlightAndBrowse() throws {
        let tree = try SyntheticTree()
        defer { tree.remove() }
        let (index, walk) = try FileIndex.build(tree.configuration)
        #expect(walk.entries > 10 && walk.unreadable == 0)
        let session = try FileSearchSession()
        for skipped in ["secret", "index.js", "cache", "Info.plist"] {
            #expect(try session.search(skipped, in: index) == 0, "\(skipped)")
        }
        try session.search("tool", in: index)
        #expect(relativePaths(session, tree) == ["Tool.app"])
        #expect(session[0].flags.contains(.package))
        try session.search("docs readme", in: index)
        #expect(relativePaths(session, tree).first == "docs/readme.md")
        #expect(session[0].match == .ancestor)
        try session.search("readme", in: index)
        let found = relativePaths(session, tree)
        #expect(found.contains("docs/readme.md") && found.contains("projects/app/README.md"))
        #expect(try session.highlightRanges(for: session[0]) == [HighlightRange(location: 0, length: 6)])
        try session.search("creme", in: index)
        #expect(relativePaths(session, tree) == ["café/crème brûlée.txt"])
        var reused: [HighlightRange] = []
        #expect(try session.highlightRanges(for: session[0], into: &reused) == 1)
        #expect(reused == [HighlightRange(location: 0, length: 5)])
        try session.search(".pdf", in: index)
        #expect(session[0].match == .filter)
        try session.search("app", in: index, options: FileSearchOptions(kinds: .folders))
        #expect((0..<session.count).allSatisfy { session[$0].flags.contains(.directory) })
        // Entries, snapshots and a subtree.
        let snapshot = try #require(session.snapshot())
        let docs = try #require(snapshot.lookup(path: tree.path("docs")))
        #expect(snapshot.entry(docs)?.flags.contains(.directory) == true)
        #expect(snapshot.entry(docs)?.size == nil)
        #expect(snapshot.lookup(path: tree.path("docs/nothing")) == nil)
        #expect(snapshot.info.entries == (try index.count()))
        try session.search("re", in: index, options: FileSearchOptions(within: docs))
        #expect(!relativePaths(session, tree).isEmpty)
        #expect(relativePaths(session, tree).allSatisfy { $0.hasPrefix("docs/") })
        try session.search("beach", in: index)
        let beach = session[0].id
        #expect(session.entry(beach)?.size == 9_000)
        #expect(session.entry(beach)?.nameLength == 9)
        let bytes = session.withPath(of: beach) { Array($0) }
        #expect(bytes == Array(tree.path("photos/beach.jpg").utf8))
        #expect(session.path(of: FileEntryID(rawValue: .max)) == nil)
        // Browse.
        session.setHome(tree.root.path)
        try session.search("~/docs/", in: index)
        #expect(session.count == 3 && (0..<3).allSatisfy { session[$0].match == .browse })
        try session.search("/nonexistent-folder/", in: index)
        #expect(session.count == 0 && session.stats.notIndexed)
        // Narrowing.
        session.reset()
        try session.search("m", in: index)
        #expect(!session.stats.narrowed)
        try session.search("ma", in: index)
        try session.search("mai", in: index)
        #expect(session.stats.narrowed)
    }

    @Test func eventsSaveOpenAndSnapshots() throws {
        let tree = try SyntheticTree()
        let store = try SyntheticTree()
        defer {
            tree.remove()
            store.remove()
        }
        let (index, _) = try FileIndex.build(tree.configuration)
        let session = try FileSearchSession()
        let before = try index.count()
        let old = try index.snapshot()
        let agenda = try tree.file("docs/agenda.txt", size: 3)
        let created: UInt32 = 0x100 | 0x1_0000
        let stats = try index.apply([FileEvent(path: agenda, flags: created)])
        #expect(stats.added == 1 && stats.published)
        #expect(try index.count() == before + 1)
        try session.search("agenda", in: index)
        #expect(relativePaths(session, tree) == ["docs/agenda.txt"])
        #expect(old.lookup(path: agenda) == nil, "an old snapshot keeps its old view")
        let file = store.path("files.idx")
        try index.save(to: file, eventID: 42)
        let (reopened, info) = try FileIndex.openOrBuild(at: file, tree.configuration)
        #expect(info.opened && info.loadError == nil && info.eventID == 42 && info.entries == before + 1)
        var hidden = tree.configuration
        hidden.includeHidden = true
        let (other, mismatch) = try FileIndex.openOrBuild(at: file, hidden)
        #expect(!mismatch.opened && mismatch.loadError == .mismatch && mismatch.walk.entries > 0)
        try session.search("secret", in: other)
        #expect(relativePaths(session, tree) == [".hidden/secret.txt"])
        #expect(try FileIndex.openOrBuild(at: store.path("missing.idx"), tree.configuration).info.loadError == .missing)
        #expect(throws: CoreError.io) { try index.save(to: "/nonexistent-folder/files.idx", eventID: 1) }
        try FileManager.default.removeItem(atPath: agenda)
        try index.apply([FileEvent(path: agenda, flags: 0x200 | 0x1_0000)])
        #expect(try session.search("agenda", in: index) == 0)
        #expect(try index.rebuild().entries > 0)
        // A snapshot outlives its index.
        let kept = try reopened.snapshot()
        _ = consume reopened
        let id = try #require(kept.lookup(path: tree.path("photos/beach.jpg")))
        #expect(kept.path(of: id) == tree.path("photos/beach.jpg"))
    }

    @Test func badConfigurationsAreRefused() throws {
        #expect(throws: CoreError.invalidArgument) {
            try FileIndex.build(FileIndexConfiguration(roots: ["relative/folder"]))
        }
        #expect(throws: CoreError.invalidArgument) {
            try FileIndex.synthetic(root: "relative", entries: 10, seed: 1)
        }
        #expect(throws: CoreError.invalidArgument) {
            try FileIndex.openOrBuild(at: "", FileIndexConfiguration(roots: ["/nonexistent-root"]))
        }
    }

    @Test func parallelSearchEqualsOneThread() throws {
        let index = try FileIndex.synthetic(root: "/synthetic/corebridge", entries: 30_000, seed: 9)
        #expect(try index.count() >= 30_000)
        let one = try FileSearchSession()
        let many = try FileSearchSession()
        for query in ["r", "re", "rep", "report", "docs readme", ".pdf", "raedme", "café"] {
            try one.search(query, in: index, options: FileSearchOptions(parallel: false))
            try many.search(query, in: index, options: FileSearchOptions(parallel: true))
            #expect(one.count == many.count, "\(query)")
            #expect((0..<one.count).allSatisfy { one[$0] == many[$0] }, "\(query)")
        }
    }

    @Test func manyTasksSearchWhileTheIndexChanges() async throws {
        let tree = try SyntheticTree()
        defer { tree.remove() }
        let (index, _) = try FileIndex.build(tree.configuration)
        try await withThrowingTaskGroup(of: Int.self) { group in
            for task in 0..<4 {
                group.addTask {
                    let session = try FileSearchSession(capacity: 20)
                    var resolved = 0
                    for i in 0..<200 {
                        let query = ["readme", "doc", "main", "churn", "b"][(i + task) % 5]
                        let n = try session.search(
                            query, in: index, options: FileSearchOptions(parallel: task % 2 == 0))
                        for k in 0..<n where session.path(of: session[k].id) != nil { resolved += 1 }
                    }
                    return resolved
                }
            }
            group.addTask {
                for i in 0..<20 {
                    let path = try tree.file("docs/churn-\(i).txt", size: 1)
                    try index.apply([FileEvent(path: path, flags: 0x100 | 0x1_0000)])
                }
                return 0
            }
            var total = 0
            for try await n in group { total += n }
            #expect(total > 0)
        }
    }
}
