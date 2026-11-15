import Foundation
import Kit
import KitTesting
import Testing

@testable import Clipboard

/// Times the history at 50,000 items: opening the page, one search keystroke, and recording one
/// copy. Opt in with `CLIPBOARD_BENCHMARK=1`, in a release build:
///
///     CLIPBOARD_BENCHMARK=1 scripts/swiftpm.sh Packages/Features/Clipboard test -c release \
///         -Xswiftc -enable-testing --filter HistoryBenchmark
///
/// The history is synthetic: words from a fixed list, links under example.com, and paths under
/// /tmp. It prints counts and milliseconds only.
@Suite(
    "Benchmark: a history of 50,000 items", .serialized, .timeLimit(.minutes(10)),
    .enabled(if: ProcessInfo.processInfo.environment["CLIPBOARD_BENCHMARK"] == "1"))
@MainActor
struct HistoryBenchmark {
    static let itemCount = 50_000

    @Test func openingTheHistory() async throws {
        let clipboard = try await Self.filledHistory()
        let list = try Self.list(clipboard)
        var samples: [Double] = []
        var rows = 0
        for _ in 0..<200 {
            samples.append(
                try await Self.time {
                    let result = try await list.load(ListRequest(reason: .open))
                    rows = result.sections.reduce(0) { $0 + $1.rows.count }
                })
        }
        Self.report("open, first page, wall", samples, extra: "rows=\(rows)")
        let filtered = try await Self.samples(50) {
            _ = try await list.load(ListRequest(filter: "images", reason: .filter))
        }
        Self.report("open, images filter, wall", filtered)
    }

    @Test func searchKeystrokes() async throws {
        let clipboard = try await Self.filledHistory()
        let list = try Self.list(clipboard)
        let queries = ["a", "co", "cop", "copper", "copper lantern", "example.com", "zzzq", "lantern ri", "#4"]
        for query in queries {
            var rows = 0
            let samples = try await Self.samples(50) {
                let result = try await list.load(ListRequest(query: query, reason: .query))
                rows = result.sections.reduce(0) { $0 + $1.rows.count }
            }
            Self.report("search \"\(query)\", wall", samples, extra: "rows=\(rows)")
        }
        for (query, filter) in [("copper", "links"), ("copper", "colors"), ("copper", "pinned"), ("example", "text")] {
            var rows = 0
            let samples = try await Self.samples(50) {
                let result = try await list.load(ListRequest(query: query, filter: filter, reason: .query))
                rows = result.sections.reduce(0) { $0 + $1.rows.count }
            }
            Self.report("search \"\(query)\" in \(filter), wall", samples, extra: "rows=\(rows)")
        }
        let store = clipboard.store
        for query in ["co", "copper", "zzzq"] {
            let samples = try await Self.samples(50) {
                _ = try await store.page(PageRequest(query: SearchQuery(query)))
            }
            Self.report("store only \"\(query)\"", samples)
        }
    }

    @Test func recordingOneCopy() async throws {
        let clipboard = try await Self.filledHistory()
        var samples: [Double] = []
        for index in 0..<200 {
            let entry = PasteboardEntry(
                contents: [.text("benchmark copy \(index) " + Self.sentence(seed: index))],
                sourceBundleID: "com.example.editor", date: clipboard.fakes.clock.now, changeCount: index)
            samples.append(try await Self.time { _ = await clipboard.feature.recorder.record(entry) })
        }
        Self.report("record one copy, wall, off main", samples)
        var repeats: [Double] = []
        for index in 0..<100 {
            let entry = PasteboardEntry(
                contents: [.text("benchmark copy \(index) " + Self.sentence(seed: index))],
                sourceBundleID: "com.example.editor", date: clipboard.fakes.clock.now, changeCount: index)
            repeats.append(try await Self.time { _ = await clipboard.feature.recorder.record(entry) })
        }
        Self.report("record a repeated copy, wall, off main", repeats)
    }

    // MARK: - Helpers

    private static let words = [
        "copper", "lantern", "river", "stone", "maple", "orbit", "velvet", "harbor", "cobalt", "meadow", "signal",
        "quartz", "willow", "ember", "canyon", "pixel", "summit", "drift", "falcon", "garnet", "a", "of", "to", "in",
    ]

    static func sentence(seed: Int) -> String {
        var state = UInt64(truncatingIfNeeded: seed &* 2_654_435_761 &+ 1)
        var parts: [String] = []
        let count = 4 + Int(state % 60)
        for _ in 0..<count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            parts.append(words[Int((state >> 33) % UInt64(words.count))])
        }
        return parts.joined(separator: " ")
    }

    /// A history of 50,000 synthetic items: mostly text, with links, colors and file paths.
    static func filledHistory() async throws -> ClipboardHarness {
        let fakes = FakeServices()
        ClipboardHarness.settings(fakes)[ClipboardSettings.maximumItems] = 100_000
        let clipboard = await ClipboardHarness(fakes: fakes)
        let start = fakes.clock.now.addingTimeInterval(-Double(itemCount) * 60)
        var batch: [(capture: Capture, date: Date)] = []
        for index in 0..<itemCount {
            let contents: [PasteboardContent]
            switch index % 50 {
            case 0..<3: contents = [.url(URL(string: "https://example.com/page/\(index)")!)]
            case 3: contents = [.text(String(format: "#%06X", index * 2_654_435 % 0xFFFFFF))]
            case 4: contents = [.files([URL(filePath: "/tmp/benchmark/file-\(index).txt")])]
            default: contents = [.text("\(index) " + sentence(seed: index))]
            }
            let capture = try #require(TemporaryStore.capture(contents))
            batch.append((capture, start.addingTimeInterval(Double(index) * 60)))
        }
        let seconds = try await time { try await clipboard.store.record(batch: batch) }
        try await clipboard.store.setPinned(true, key: batch[10].capture.key)
        let count = try await clipboard.store.count()
        print("benchmark: inserted \(count) items in \(String(format: "%.0f", seconds)) ms")
        return clipboard
    }

    static func list(_ clipboard: ClipboardHarness) throws -> any ListSource {
        _ = try clipboard.harness.command("history")
        let page = HistoryList(
            store: clipboard.store, changes: clipboard.feature.changes,
            actions: HistoryActions(
                store: clipboard.store, changes: clipboard.feature.changes, context: clipboard.harness.context),
            context: clipboard.harness.context)
        return page
    }

    static func samples(_ count: Int, _ body: () async throws -> Void) async throws -> [Double] {
        var samples: [Double] = []
        for _ in 0..<count { samples.append(try await time(body)) }
        return samples
    }

    static func time(_ body: () async throws -> Void) async throws -> Double {
        let start = ContinuousClock.now
        try await body()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
    }

    static func report(_ name: String, _ samples: [Double], extra: String = "") {
        let sorted = samples.sorted()
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let line = String(
            format: "benchmark: %@ n=%d p50=%.2f ms p99=%.2f ms max=%.2f ms %@", name, sorted.count, percentile(0.5),
            percentile(0.99), sorted.last ?? 0, extra)
        print(line)
    }
}
