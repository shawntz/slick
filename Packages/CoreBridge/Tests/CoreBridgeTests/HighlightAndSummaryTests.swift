import Foundation
import Testing

@testable import CoreBridge

@Suite("Highlights into a reused array, and the learning summary")
struct HighlightAndSummaryTests {
    let items = [
        app("Safari"),
        app("Terminal"),
        CatalogItem(key: ItemKey(id: "cmd:cafe"), title: "🎉 Café Finder", kind: .command),
    ]

    @Test func theReusingVariantsEqualTheArrayVariant() throws {
        let engine = try makeEngine(items)
        let index = try FuzzyIndex()
        try index.setItems(items)
        let buffer = try QueryBuffer()
        var ranges: [HighlightRange] = []
        var offsets: [Range<Int>] = []
        for query in ["saf", "term", "cafe", "fndr", "zzz"] {
            try engine.query(query, into: buffer)
            for item in items {
                let expected = try engine.highlightRanges(for: item.key, in: buffer)
                #expect(try engine.highlightRanges(for: item.key, in: buffer, into: &ranges) == expected.count)
                #expect(ranges == expected)
                try engine.highlightRanges(for: item.key, in: buffer, into: &offsets)
                #expect(offsets == expected.map { $0.location..<($0.location + $0.length) })
            }
            try index.query(query, into: buffer)
            for item in items {
                let expected = try index.highlightRanges(for: item.key, in: buffer)
                try index.highlightRanges(for: item.key, in: buffer, into: &ranges)
                #expect(ranges == expected)
                try index.highlightRanges(for: item.key, in: buffer, into: &offsets)
                #expect(offsets.count == expected.count)
            }
        }
        try engine.query("cafe", into: buffer)
        try engine.highlightRanges(for: items[2].key, in: buffer, into: &ranges)
        #expect(ranges == [HighlightRange(location: 3, length: 4)], "UTF-16 units after the emoji")
    }

    @Test func theSummaryCountsRunsItemsQueriesAndTheFirstRun() throws {
        let engine = try makeEngine(items)
        let empty = try engine.summary()
        #expect(empty.events == 0 && empty.items == 0 && empty.queries == 0 && empty.firstEvent == nil)
        try engine.recordExecution(of: items[1].key, query: "te", source: .typed, at: t0 + 60)
        try engine.recordExecution(of: items[1].key, query: "te", source: .typed, at: t0 + 120)
        try engine.recordExecution(of: items[0].key, query: "", source: .suggestion, at: t0 + 180)
        let summary = try engine.summary()
        #expect(summary.events == 3 && summary.items == 2 && summary.queries == 2)
        #expect(abs((summary.firstEvent ?? 0) - (t0 + 60)) < 61)
        // After forgetting "term", "te" and "t" keep their text in the statistics.
        try engine.recordExecution(of: items[1].key, query: "term", source: .typed, at: t0 + 240)
        #expect(try engine.forgetQuery("term"))
        let json = try engine.statisticsJSON()
        #expect(json.contains("\"query\":\"ter\"") && json.contains("\"first_event\":"))
        try engine.forget(items[1].key)
        #expect(try engine.summary().items == 1)
        try engine.resetLearning()
        #expect(try engine.summary().firstEvent == nil)
    }
}
