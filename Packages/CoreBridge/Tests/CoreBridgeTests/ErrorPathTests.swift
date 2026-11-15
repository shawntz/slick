import Foundation
import Testing

@testable import CoreBridge

/// The edges of the Swift API: limits, refusals, oversized results and strings that are not stored
/// as contiguous UTF-8.
@Suite("Error paths")
struct ErrorPathTests {
    func temporaryDirectory(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/test-data/\(name)-\(ProcessInfo.processInfo.processIdentifier)")
    }

    @Test func aSecondEngineOnTheSameDirectoryIsRefused() throws {
        let directory = temporaryDirectory("two-engines")
        try? FileManager.default.removeItem(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let first = try Engine(directory: directory.path)
            #expect(throws: CoreError.io) { try Engine(directory: directory.path) }
            try first.flush()
        }
        // Once the first engine is gone the directory opens again.
        _ = try Engine(directory: directory.path)
    }

    @Test func aZeroLimitReturnsNoSuggestions() throws {
        let engine = try makeEngine([app("Safari"), app("Notes")])
        try engine.recordExecution(of: ItemKey(id: "app:Safari"), query: "", source: .suggestion, at: t0)
        #expect(try engine.suggestions(limit: 1).count == 1)
        #expect(try engine.suggestions(limit: 0).isEmpty)
        #expect(try engine.suggestions(limit: -3).isEmpty)
    }

    @Test func aCompletionTooLongForTheBufferIsNoCompletion() throws {
        let long = CatalogItem(key: ItemKey(id: "clip:long"), title: "zq" + String(repeating: "x", count: 4_000))
        let engine = try makeEngine([long])
        let buffer = try QueryBuffer()
        try engine.query("zq", into: buffer)
        #expect(buffer.count == 1)
        #expect(try engine.completion(in: buffer) == nil)
        // A completion that fits still comes back.
        let short = try makeEngine([CatalogItem(key: ItemKey(id: "app:z"), title: "zqx Studio")])
        try short.query("zq", into: buffer)
        #expect(try short.completion(in: buffer)?.text == "x Studio")
    }

    @Test func longStatisticsGrowTheirBuffer() throws {
        let engine = try makeEngine([app("Safari")])
        let safari = ItemKey(id: "app:Safari")
        // Distinct queries add affinity rows until the JSON is well past its first 16 KB buffer.
        var n = 0
        for a in "abcdefghij" {
            for b in "abcdefghij" {
                try engine.recordExecution(of: safari, query: "\(a)\(b)q", source: .typed, at: t0 + Double(n))
                n += 1
            }
        }
        let json = try engine.statisticsJSON()
        #expect(json.utf8.count > 16 * 1024)
        #expect(try JSONSerialization.jsonObject(with: Data(json.utf8)) is [String: Any])
    }

    @Test func queriesLongerThanTheScratchSpaceAreCutOnACharacterBoundary() throws {
        let engine = try makeEngine([app("Safari")])
        let buffer = try QueryBuffer()
        // A bridged string has no contiguous UTF-8, so it goes through the 1 KB scratch space. Two
        // byte characters put a boundary right at the cut.
        for prefix in ["", "s", "sa"] {
            let s = NSMutableString(string: prefix)
            s.append(String(repeating: "é", count: 2_000))
            #expect(try engine.query(s as String, into: buffer) == 0)
        }
        let s = NSMutableString(string: "saf")
        #expect(try engine.query(s as String, into: buffer) == 1)
    }

    @Test func keywordsWithTheSeparatorAreRefusedAndChangeNothing() throws {
        let engine = try makeEngine([app("Safari")])
        let bad = CatalogItem(key: ItemKey(id: "x"), title: "X", keywords: ["a\u{1f}b"])
        #expect(throws: CoreError.invalidArgument) { try engine.replaceSource(1, with: [app("Notes"), bad]) }
        #expect(try engine.count() == 1)
        let index = try FuzzyIndex()
        #expect(throws: CoreError.invalidArgument) { try index.setItems([bad]) }
        #expect(try index.count() == 0)
    }

    @Test func queriesRunWhileOtherTasksChangeTheCatalogAndLearn() async throws {
        let engine = try makeEngine([app("Safari"), app("Terminal"), app("Term")])
        let index = try FuzzyIndex()
        try index.setItems([app("Safari"), app("Notes")])
        let catalogs = [
            [app("Safari"), app("Terminal"), app("Term")],
            (0..<300).map { CatalogItem(key: ItemKey(id: "cmd:\($0)"), title: "Tool \($0)") } + [app("Terminal")],
        ]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    let buffer = try QueryBuffer()
                    for q in Array(repeating: ["t", "te", "ter", "term", "s", "saf"], count: 60).joined() {
                        let n = try engine.query(q, into: buffer)
                        for i in 0..<n { _ = try engine.highlightRanges(for: buffer[i].key, in: buffer) }
                        _ = try engine.completion(in: buffer)
                        try index.query(q, into: buffer)
                    }
                }
            }
            group.addTask {
                for round in 0..<60 {
                    try engine.replaceSource(1, with: catalogs[round % 2])
                    try index.setItems(catalogs[(round + 1) % 2])
                }
            }
            group.addTask {
                for k in 0..<200 {
                    try engine.recordExecution(
                        of: ItemKey(id: "app:Terminal"), query: "term", source: .typed, at: t0 + Double(k))
                    try engine.setContext(EngineContext(now: t0 + Double(k), hour: 9, weekday: 0))
                    _ = try engine.suggestions()
                    _ = try engine.statisticsJSON()
                }
            }
            try await group.waitForAll()
        }
        let buffer = try QueryBuffer()
        try engine.query("term", into: buffer)
        #expect(buffer[0].key == ItemKey(id: "app:Terminal") && buffer[0].flags.contains(.learned))
    }
}
