import Foundation
import Testing

@testable import CoreBridge

@Suite("Forgetting a query", .timeLimit(.minutes(2)))
struct ForgetQueryTests {
    let items = [app("Term"), app("Terminal")]

    @Test func aForgottenQueryRanksByTextAgain() throws {
        let engine = try makeEngine(items)
        let buffer = try QueryBuffer()
        for k in 1...2 {
            try engine.recordExecution(of: items[1].key, query: "term", source: .typed, at: t0 + Double(k))
        }
        try engine.query("term", into: buffer)
        #expect(buffer[0].key == items[1].key && buffer[0].flags.contains(.learned))
        #expect(try engine.forgetQuery(" TERM "))
        #expect(try !engine.forgetQuery("term"))
        #expect(try !engine.forgetQuery(""))
        try engine.query("term", into: buffer)
        #expect(buffer[0].key == items[0].key)
        let learned = (0..<buffer.count).contains {
            !buffer[$0].flags.intersection([.learned, .affinity]).isEmpty
        }
        #expect(!learned)
    }

    @Test func theStatisticsNameEachRowsBandHolder() throws {
        let engine = try makeEngine(items)
        for k in 1...2 {
            try engine.recordExecution(of: items[1].key, query: "te", source: .typed, at: t0 + Double(k))
        }
        let json = try engine.statisticsJSON()
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let rows = object?["affinity"] as? [[String: Any]] ?? []
        let row = { (query: String) in rows.first { $0["query"] as? String == query } }
        #expect(row("te")?["band"] as? String == String(items[1].key.rawValue))
        // "t" got half credit twice, below the band.
        #expect(row("t")?["band"] is NSNull)
    }
}
