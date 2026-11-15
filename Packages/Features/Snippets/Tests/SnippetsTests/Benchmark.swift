import Foundation
import Kit
import KitTesting
import Testing

@testable import Snippets

/// Timings with a thousand snippets. Off by default; run with `SNIPPETS_BENCHMARK=1`, in release:
/// `SNIPPETS_BENCHMARK=1 scripts/swiftpm.sh Packages/Features/Snippets test -c release -Xswiftc -enable-testing
/// --filter Benchmark`. It prints counts and times only.
@Suite(
    "Benchmark", .serialized, .timeLimit(.minutes(5)),
    .enabled(if: ProcessInfo.processInfo.environment["SNIPPETS_BENCHMARK"] == "1"))
struct Benchmark {
    static let count = 1000
    static let runs = 200

    /// Synthetic snippets: ten collections, every tenth pinned, a third with placeholders.
    static func library() -> [Snippet] {
        (0..<count).map { number in
            let name = "Snippet \(number)"
            var text = "Line one of snippet \(number) with some words to search\nSecond line"
            if number % 3 == 0 { text += " {date format=\"yyyy-MM-dd\"} {clipboard} {cursor}" }
            if number % 50 == 0 { text += " {argument name=\"value\"}" }
            return Fixture.snippet(
                name, text, keyword: "k\(number)", collection: number % 4 == 0 ? nil : "Collection \(number % 10)",
                pinned: number % 10 == 0, id: "bench-\(number)")
        }
    }

    /// p50, p99 and max in milliseconds.
    static func report(_ label: String, _ samples: [Double]) {
        let sorted = samples.sorted()
        func at(_ fraction: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))] }
        let line = String(
            format: "BENCH %@ n=%d p50=%.4f ms p99=%.4f ms max=%.4f ms", label, sorted.count, at(0.5), at(0.99),
            sorted.last ?? 0)
        print(line)
    }

    /// CPU time of the current thread, in milliseconds.
    static func threadCPU() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000
    }

    static func wall() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000
    }

    static func load() -> String {
        var loads = [0.0, 0.0, 0.0]
        getloadavg(&loads, 3)
        return String(format: "%.2f %.2f %.2f", loads[0], loads[1], loads[2])
    }

    @Test func openingSearchSnippets() async throws {
        print("BENCH load at start: \(Self.load())")
        let harness = try await FeatureHarness.loaded(Self.library())
        let source = try #require(harness.feature.catalogSources.first as? SnippetSource)
        // Warm up.
        _ = try await source.load(ListRequest())
        var wallTimes: [Double] = []
        var mainTimes: [Double] = []
        for _ in 0..<Self.runs {
            let (wallStart, cpuStart) = (Self.wall(), Self.threadCPU())
            let result = try await source.load(ListRequest())
            wallTimes.append(Self.wall() - wallStart)
            mainTimes.append(Self.threadCPU() - cpuStart)
            #expect(result.sections.reduce(0) { $0 + $1.rows.count } == Self.count)
        }
        Self.report("list load, wall", wallTimes)
        Self.report("list load, main-thread CPU", mainTimes)

        var commandTimes: [Double] = []
        for _ in 0..<50 {
            let start = Self.wall()
            try await harness.openSearch()
            commandTimes.append(Self.wall() - start)
            harness.pop()
        }
        Self.report("Search Snippets command to rows, wall, with the fake index", commandTimes)
        print("BENCH load at end: \(Self.load())")
    }

    @Test func interactionPathsOnTheMainThread() async throws {
        print("BENCH load at start: \(Self.load())")
        let harness = try await FeatureHarness.loaded(Self.library())
        let source = try #require(harness.feature.catalogSources.first as? SnippetSource)
        let queries = ["k5", "k999", "kx", "Snippet", "zebra", "k", "k50", ";k1"]
        var answerTimes: [Double] = []
        for _ in 0..<Self.runs {
            for query in queries {
                let start = Self.threadCPU()
                _ = source.answer(for: query)
                answerTimes.append(Self.threadCPU() - start)
            }
        }
        Self.report("instant answer, main-thread CPU", answerTimes)

        let rows = try await harness.catalogRows()
        var actionTimes: [Double] = []
        for row in rows.prefix(Self.runs) {
            let start = Self.threadCPU()
            let actions = source.actions(for: row)
            actionTimes.append(Self.threadCPU() - start)
            #expect(actions.count == 7)
        }
        Self.report("actions(for:), main-thread CPU", actionTimes)

        var detailTimes: [Double] = []
        for row in rows.prefix(Self.runs) {
            let start = Self.wall()
            _ = try await source.detail(for: row)
            detailTimes.append(Self.wall() - start)
        }
        Self.report("detail(for:), wall", detailTimes)
        print("BENCH load at end: \(Self.load())")
    }

    @Test func keywordChangeAndIndexBuild() async throws {
        print("BENCH load at start: \(Self.load())")
        let fakes = FakeServices()
        fakes.context(featureID: SnippetIDs.feature).settings[SnippetsSettings.expansionEnabled] = true
        let harness = try await FeatureHarness.loaded(Self.library(), fakes: fakes)
        #expect(fakes.textExpansion.keywords.count == Self.count)

        var indexTimes: [Double] = []
        let snippets = Self.library()
        for _ in 0..<50 {
            let start = Self.wall()
            _ = await LibraryIndex.build(snippets)
            indexTimes.append(Self.wall() - start)
        }
        Self.report("index build for \(Self.count), wall, background", indexTimes)

        var saveTimes: [Double] = []
        var mainTimes: [Double] = []
        for number in 0..<50 {
            let (wallStart, cpuStart) = (Self.wall(), Self.threadCPU())
            try await harness.library.update(
                id: "bench-\(number)", with: SnippetDraft(name: "Changed \(number)", text: "x", keyword: "c\(number)"))
            saveTimes.append(Self.wall() - wallStart)
            mainTimes.append(Self.threadCPU() - cpuStart)
        }
        #expect(fakes.textExpansion.keywords.contains("c49"))
        Self.report("keyword change: save, index, re-register, wall", saveTimes)
        Self.report("keyword change: main-thread CPU", mainTimes)
        print("BENCH load at end: \(Self.load())")
    }
}
