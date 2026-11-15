import Foundation
import Testing

@testable import CoreBridge

let t0 = 1_780_000_000.0

func app(_ title: String) -> CatalogItem {
    CatalogItem(key: ItemKey(id: "app:\(title)"), title: title, kind: .app)
}

func makeEngine(_ items: [CatalogItem], directory: String? = nil) throws -> Engine {
    let engine = try Engine(directory: directory)
    try engine.replaceSource(1, with: items)
    try engine.setContext(EngineContext(now: t0, hour: 9, weekday: 0))
    return engine
}

func keys(_ buffer: QueryBuffer) -> [ItemKey] {
    (0..<buffer.count).map { buffer[$0].key }
}

@Suite("Engine", .timeLimit(.minutes(2)))
struct EngineTests {
    let items = [
        app("Safari"),
        app("Term"),
        app("Terminal"),
        CatalogItem(key: ItemKey(id: "cmd:cafe"), title: "🎉 Café Finder", keywords: ["coffee"], kind: .command),
        CatalogItem(key: ItemKey(id: "cmd:trash"), title: "Empty Trash", kind: .command, flags: .noSuggest),
    ]

    @Test func queriesRankAndHighlight() throws {
        let engine = try makeEngine(items)
        let buffer = try QueryBuffer()
        #expect(try engine.count() == 5)
        try engine.query("term", into: buffer)
        #expect(keys(buffer).prefix(2) == [items[1].key, items[2].key])
        #expect(buffer[0].tier == 6 && buffer[0].field == .title && buffer[0].kind == .app)
        try engine.query("coffee", into: buffer)
        #expect(buffer[0].key == items[3].key && buffer[0].field == .keyword)
        try engine.query("cafe", into: buffer)
        let ranges = try engine.highlightRanges(for: items[3].key, in: buffer)
        // The emoji is two UTF-16 units and a space, so "Café" starts at 3.
        #expect(ranges == [HighlightRange(location: 3, length: 4)])
    }

    @Test func learningTheBandCompletionAndUndo() throws {
        let engine = try makeEngine(items)
        let buffer = try QueryBuffer()
        for k in 1...2 {
            #expect(
                try engine.recordExecution(of: items[2].key, query: "term", source: .typed, rank: 1, at: t0 + Double(k))
            )
        }
        try engine.query("term", into: buffer)
        #expect(buffer[0].key == items[2].key && buffer[0].flags.contains(.learned) && buffer[0].tier == 8)
        let completion = try engine.completion(in: buffer)
        #expect(completion?.key == items[2].key && completion?.text == "inal")
        #expect(try engine.undoExecution(of: items[2].key, at: t0 + 4))
        try engine.query("term", into: buffer)
        #expect(buffer[0].key == items[1].key)
    }

    @Test func suggestionsSkipTheFrontmostAppAndOptedOutItems() throws {
        let engine = try makeEngine(items)
        for (k, item) in [items[0], items[2], items[4]].enumerated() {
            try engine.recordExecution(of: item.key, query: "", source: .suggestion, at: t0 + Double(k))
        }
        let all = try engine.suggestions().map(\.key)
        #expect(all.contains(items[0].key) && !all.contains(items[4].key))
        try engine.setContext(EngineContext(now: t0 + 10, hour: 9, weekday: 0, frontmost: items[0].key))
        #expect(try !engine.suggestions().map(\.key).contains(items[0].key))
    }

    @Test func aliasesStatisticsAndReset() throws {
        let engine = try makeEngine(items)
        let buffer = try QueryBuffer()
        try engine.setAlias("sf", for: items[0].key)
        try engine.query("sf", into: buffer)
        #expect(buffer[0].key == items[0].key && buffer[0].field == .userAlias && buffer[0].flags.contains(.alias))
        try engine.recordExecution(of: items[0].key, query: "saf", source: .typed, at: t0 + 1)
        try engine.seed(items[1].key, weight: 0.3, at: t0)
        let json = try engine.statisticsJSON()
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let counts = object?["counts"] as? [String: Int]
        #expect(counts?["events"] == 1 && counts?["seeds"] == 1)
        #expect((object?["affinity"] as? [Any])?.count == 3)
        try engine.forget(items[0].key)
        try engine.setLearningPaused(true)
        #expect(try !engine.recordExecution(of: items[0].key, query: "saf", source: .typed, at: t0 + 2))
        try engine.setLearningPaused(false)
        try engine.resetLearning()
        #expect(try engine.suggestions().isEmpty)
    }

    @Test func catalogChangesAndBadInput() throws {
        let engine = try makeEngine(items)
        let buffer = try QueryBuffer()
        try engine.upsert(app("Saxophone"), source: 2)
        try engine.query("sax", into: buffer)
        #expect(buffer[0].key == ItemKey(id: "app:Saxophone"))
        try engine.remove(ItemKey(id: "app:Saxophone"))
        #expect(try engine.count() == 5)
        let bad = CatalogItem(key: ItemKey(id: "x"), title: "X", aliases: ["a\u{1f}b"])
        #expect(throws: CoreError.invalidArgument) { try engine.upsert(bad, source: 1) }
        #expect(throws: CoreError.io) { try Engine(directory: "/dev/null/not-a-directory") }
    }

    @Test func learningPersistsAcrossLaunches() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/test-data/engine-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let engine = try makeEngine(items, directory: directory.path)
            for k in 1...2 {
                try engine.recordExecution(of: items[2].key, query: "term", source: .typed, at: t0 + Double(k))
            }
            try engine.flush()
        }
        let reopened = try makeEngine(items, directory: directory.path)
        let buffer = try QueryBuffer()
        try reopened.query("term", into: buffer)
        #expect(buffer[0].key == items[2].key)
    }

    @Test func queriesRunConcurrentlyWithTheirOwnBuffers() async throws {
        let engine = try makeEngine(items)
        let firsts = try await withThrowingTaskGroup(of: ItemKey?.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let buffer = try QueryBuffer()
                    for _ in 0..<200 { try engine.query("term", into: buffer) }
                    return buffer.count > 0 ? buffer[0].key : nil
                }
            }
            return try await group.reduce(into: [ItemKey?]()) { $0.append($1) }
        }
        #expect(firsts.allSatisfy { $0 == items[1].key })
    }
}

@Suite("Fuzzy index", .timeLimit(.minutes(2)))
struct FuzzyIndexTests {
    @Test func setQueryAndHighlight() throws {
        let index = try FuzzyIndex()
        let party = CatalogItem(key: ItemKey(id: "emoji:party"), title: "Party Popper 🎉", keywords: ["celebrate"])
        let grin = CatalogItem(key: ItemKey(id: "emoji:grin"), title: "Grinning Face 😀", keywords: ["smile"])
        try index.setItems([party, grin])
        #expect(try index.count() == 2)
        let buffer = try QueryBuffer(capacity: 10)
        try index.query("smile", into: buffer)
        #expect(keys(buffer) == [grin.key])
        try index.query("party", into: buffer)
        #expect(try index.highlightRanges(for: party.key, in: buffer) == [HighlightRange(location: 0, length: 5)])
    }
}
