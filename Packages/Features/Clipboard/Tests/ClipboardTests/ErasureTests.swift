import Foundation
import Kit
import Testing

@testable import Clipboard

/// What a deleted item leaves in the history's files. The store stays open, as it does in the
/// launcher, and the test reads the database and its write-ahead log as bytes, as anyone with a
/// copy of the folder could. Every text here is made up.
@Suite("Deleted history leaves nothing to read", .timeLimit(.minutes(1)))
struct ErasureTests {
    private let date = Date(timeIntervalSince1970: 1_794_648_600)
    /// A made-up secret. The full-text index stores its text as lower-case trigrams; these five
    /// appear in no other text here.
    static let secret = "Qxzjvkwq-synthetic"
    static let secretTrigrams = ["xzj", "zjv", "jvk", "vkw", "kwq"]
    /// A made-up text long enough to need overflow pages, with a marker at its end.
    static let long = String(repeating: "Mmnop", count: 4_000) + "Longmarkerqpzv"

    enum Deletion: String, CaseIterable, Sendable {
        case one, all, recent, prune
    }

    @Test(arguments: Deletion.allCases)
    func aDeletedTextCannotBeReadFromTheFiles(deletion: Deletion) async throws {
        let temporary = TemporaryStore()
        defer { temporary.remove() }
        let store = temporary.store
        // A prune removes the oldest items, the other deletions the newest, so the kept item comes
        // last for a prune and first otherwise.
        let keptAt = deletion == .prune ? date.addingTimeInterval(30) : date
        try await store.record(TemporaryStore.capture("alpha beta gamma"), at: keptAt)
        let secret = TemporaryStore.capture(Self.secret)
        try await store.record(secret, at: date.addingTimeInterval(10))
        let long = TemporaryStore.capture(Self.long)
        try await store.record(long, at: date.addingTimeInterval(20))
        if deletion == .prune { try await store.moveToTop(TemporaryStore.capture("alpha beta gamma").key, at: keptAt) }
        #expect(try await store.count() == 3)

        switch deletion {
        case .one:
            try await store.delete(secret.key)
            try await store.delete(long.key)
        case .all:
            try await store.deleteAll(keepingPinned: true)
        case .recent:
            try await store.delete(copiedSince: date.addingTimeInterval(5))
        case .prune:
            try await store.prune(PrunePolicy(cutoff: nil, maximumItems: 1, maximumImageBytes: 1 << 30))
        }
        if deletion != .all { #expect(try await store.count() == 1) }

        let bytes = try Self.fileBytes(temporary)
        for trigram in Self.secretTrigrams {
            #expect(!Self.bytes(bytes, contain: trigram), "the index still holds \(trigram)")
        }
        #expect(!Self.bytes(bytes, contain: Self.secret))
        #expect(!Self.bytes(bytes, contain: "Longmarkerqpzv"), "a freed overflow page kept its text")
        #expect(!Self.bytes(bytes, contain: "MmnopMmnopMmnop"), "a freed overflow page kept its text")
        // What was kept is still found.
        if deletion != .all {
            let page = try await store.page(PageRequest(query: SearchQuery("beta")))
            #expect(page.items.map(\.preview) == ["alpha beta gamma"])
        }
    }

    /// Prunes run after every copy, so they rewrite the index at the first prune of a session and
    /// then once per ``HistoryStore/pruneRewriteThreshold`` items. A delete the user asks for
    /// always rewrites it, and one that removes nothing does not.
    @Test func theIndexIsRewrittenOnASchedule() async throws {
        let temporary = TemporaryStore()
        defer { temporary.remove() }
        let store = temporary.store
        let keep = PrunePolicy(cutoff: nil, maximumItems: 1, maximumImageBytes: 1 << 30)
        try await store.record(TemporaryStore.capture("first synthetic"), at: date)
        try await store.prune(keep)
        #expect(await store.indexRewrites == 1)
        for offset in 1...3 {
            try await store.record(
                TemporaryStore.capture("synthetic \(offset)"), at: date.addingTimeInterval(Double(offset)))
            #expect(try await store.prune(keep) == 1)
        }
        #expect(await store.indexRewrites == 1)
        #expect(try await store.delete(copiedSince: date.addingTimeInterval(100)) == 0)
        #expect(await store.indexRewrites == 1)
        try await store.deleteAll(keepingPinned: true)
        #expect(await store.indexRewrites == 2)
    }

    @Test func theDatabaseErasesWhatItFrees() async throws {
        let temporary = TemporaryStore()
        defer { temporary.remove() }
        try await temporary.store.record(TemporaryStore.capture("alpha beta gamma"), at: date)
        #expect(try await temporary.store.secureDeleteMode() == 1)
    }

    @Test func theHistoryFolderIsLeftOutOfBackups() async throws {
        let temporary = TemporaryStore()
        defer { temporary.remove() }
        try await temporary.store.record(TemporaryStore.capture("alpha beta gamma"), at: date)
        let values = try temporary.folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    /// The database file and its write-ahead log, as one run of bytes.
    static func fileBytes(_ temporary: TemporaryStore) throws -> Data {
        let database = temporary.store.databaseURL
        var bytes = try Data(contentsOf: database)
        let log = URL(filePath: database.path + "-wal")
        if FileManager.default.fileExists(atPath: log.path) { bytes += try Data(contentsOf: log) }
        return bytes
    }

    static func bytes(_ data: Data, contain text: String) -> Bool {
        data.range(of: Data(text.utf8)) != nil
    }
}
