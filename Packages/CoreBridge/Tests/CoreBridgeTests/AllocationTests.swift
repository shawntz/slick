import BenchSupport
import Foundation
import Testing

@testable import CoreBridge

/// A query allocates nothing on the calling thread once its buffer is warm, including the String
/// to UTF-8 step: native, bridged and non-ASCII strings.
///
/// The measured region calls the queries one by one and repeats them with a `while` loop: in debug
/// builds a `for` loop over a range or an array allocates on every iteration by itself, which
/// would hide what the queries do.
@Suite("Allocations", .serialized, .timeLimit(.minutes(2)))
struct AllocationTests {
    struct Fixture {
        let engine: Engine
        let index: FuzzyIndex
        let buffer: QueryBuffer
        let bridged: String
        let accented = "café crème"

        init() throws {
            let items = (0..<2_000).map { i in
                CatalogItem(key: ItemKey(id: "cmd:\(i)"), title: "Search Service \(i) Notes", kind: .command)
            }
            engine = try makeEngine(items + [app("Safari"), app("Terminal")])
            index = try FuzzyIndex()
            try index.setItems(items)
            buffer = try QueryBuffer()
            let s = NSMutableString(string: "search ")
            s.append("serv")
            bridged = s as String
        }

        /// One typing session against the engine, then against the index.
        func type() throws -> Int {
            var n = 0
            buffer.reset()
            n += try engine.query("s", into: buffer)
            n += try engine.query("se", into: buffer)
            n += try engine.query("sea", into: buffer)
            n += try engine.query(bridged, into: buffer)
            n += try engine.query("srch", into: buffer)
            n += try engine.query(accented, into: buffer)
            n += try engine.query("term", into: buffer)
            buffer.reset()
            n += try index.query("s", into: buffer)
            n += try index.query(bridged, into: buffer)
            n += try index.query(accented, into: buffer)
            return n
        }
    }

    @Test func aQueryAllocatesNothing() throws {
        let f = try Fixture()
        var total = 0
        for _ in 0..<3 { total += try f.type() }
        var round = 0
        bench_alloc_count_begin()
        while round < 20 {
            total += try f.type()
            round += 1
        }
        let allocations = bench_alloc_count_end()
        #expect(total > 0)
        #expect(allocations == 0, "\(allocations) allocations in 20 typing sessions")
    }

    /// A query that is not math allocates nothing: the lock, the String to UTF-8 step and the
    /// Rust reject path. Native, bridged and non-ASCII strings.
    @Test func aRejectedCalculationAllocatesNothing() throws {
        let calculator = try fixedCalculator()
        let s = NSMutableString(string: "visual ")
        s.append("studio")
        let bridged = s as String
        func reject() -> Int {
            var n = 0
            if calculator.evaluate("safari", at: calcNow) == nil { n += 1 }
            if calculator.evaluate("Terminal", at: calcNow) == nil { n += 1 }
            if calculator.evaluate(bridged, at: calcNow) == nil { n += 1 }
            if calculator.evaluate("crème brûlée", at: calcNow) == nil { n += 1 }
            if calculator.evaluate("notes 2024", at: calcNow) == nil { n += 1 }
            if calculator.evaluate("42", at: calcNow) == nil { n += 1 }
            return n
        }
        var total = reject() + reject()
        var round = 0
        bench_alloc_count_begin()
        while round < 200 {
            total += reject()
            round += 1
        }
        let allocations = bench_alloc_count_end()
        #expect(total == 6 * 202)
        #expect(allocations == 0, "\(allocations) allocations in 1,200 rejected queries")
    }

    /// Highlight ranges into a reused array allocate nothing once the array has room.
    @Test func highlightsIntoAReusedArrayAllocateNothing() throws {
        let f = try Fixture()
        var ranges: [HighlightRange] = []
        var offsets: [Range<Int>] = []
        ranges.reserveCapacity(16)
        offsets.reserveCapacity(16)
        let keys = [ItemKey(id: "cmd:1"), ItemKey(id: "cmd:2"), ItemKey(id: "app:Safari")]
        try f.engine.query("search", into: f.buffer)
        var total = 0
        total += try f.engine.highlightRanges(for: keys[0], in: f.buffer, into: &ranges)
        total += try f.engine.highlightRanges(for: keys[1], in: f.buffer, into: &offsets)
        total += try f.index.highlightRanges(for: keys[2], in: f.buffer, into: &ranges)
        var round = 0
        bench_alloc_count_begin()
        while round < 100 {
            total += try f.engine.highlightRanges(for: keys[0], in: f.buffer, into: &ranges)
            round += 1
        }
        let a = bench_alloc_count_end()
        round = 0
        bench_alloc_count_begin()
        while round < 100 {
            total += try f.engine.highlightRanges(for: keys[1], in: f.buffer, into: &offsets)
            round += 1
        }
        let b = bench_alloc_count_end()
        round = 0
        bench_alloc_count_begin()
        while round < 100 {
            total += try f.index.highlightRanges(for: keys[2], in: f.buffer, into: &ranges)
            round += 1
        }
        let c = bench_alloc_count_end()
        let allocations = a + b + c
        print("highlight allocations: engine \(a), engine offsets \(b), index \(c)")
        #expect(total > 0)
        #expect(allocations == 0, "\(allocations) allocations in 300 highlight calls")
    }

    /// A warm file search allocates nothing on the calling thread, in Swift or in Rust: query
    /// parsing, the narrowing stack, the typo pass, the folder tier, path fragments and folder
    /// listings reuse their buffers. One thread, because the parallel parts run on other threads;
    /// the Rust tests count those.
    @Test func aWarmFileSearchAllocatesNothing() throws {
        let index = try FileIndex.synthetic(root: "/synthetic/alloc", entries: 20_000, seed: 3)
        let session = try FileSearchSession(capacity: 50)
        let options = FileSearchOptions(now: 1_794_000_000, parallel: false)
        let s = "s"
        let sc = "sc"
        let scr = "scr"
        let screnshot = "screnshot"
        let docs = "docs r"
        let docsRe = "docs re"
        let pdf = "report .pdf"
        let fragment = "src/ma"
        let accented = "café"
        let browse = "/synthetic/alloc/re"
        func typing() throws -> Int {
            var n = 0
            session.reset()
            n += try session.search(s, in: index, options: options)
            n += try session.search(sc, in: index, options: options)
            n += try session.search(scr, in: index, options: options)
            n += try session.search(screnshot, in: index, options: options)
            session.reset()
            n += try session.search(docs, in: index, options: options)
            n += try session.search(docsRe, in: index, options: options)
            session.reset()
            n += try session.search(pdf, in: index, options: options)
            n += try session.search(fragment, in: index, options: options)
            n += try session.search(accented, in: index, options: options)
            n += try session.search(browse, in: index, options: options)
            return n
        }
        var total = 0
        var round = 0
        while round < 3 {
            total += try typing()
            round += 1
        }
        round = 0
        bench_alloc_count_begin()
        while round < 10 {
            total += try typing()
            round += 1
        }
        let allocations = bench_alloc_count_end()
        #expect(total > 0)
        #expect(allocations == 0, "\(allocations) allocations in 100 warm file searches")
    }

    /// Reading a hit's path into the session's buffer allocates nothing.
    @Test func aPathIntoTheSessionBufferAllocatesNothing() throws {
        let index = try FileIndex.synthetic(root: "/synthetic/alloc", entries: 5_000, seed: 2)
        let session = try FileSearchSession()
        try session.search("report", in: index)
        let id = session[0].id
        var bytes = 0
        _ = session.withPath(of: id) { $0.count }
        var round = 0
        bench_alloc_count_begin()
        while round < 200 {
            bytes += session.withPath(of: id) { $0.count } ?? 0
            round += 1
        }
        let allocations = bench_alloc_count_end()
        #expect(bytes > 0)
        #expect(allocations == 0, "\(allocations) allocations in 200 path reads")
    }
}
