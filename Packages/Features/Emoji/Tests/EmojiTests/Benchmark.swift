import Darwin
import Foundation
import Kit
import KitTesting
import Testing

@testable import Emoji

/// Measures the budgets. Opt in with `EMOJI_BENCHMARK=1`, in a release build:
///
///     EMOJI_BENCHMARK=1 scripts/swiftpm.sh Packages/Features/Emoji test -c release \
///         -Xswiftc -enable-testing --filter Benchmark
///
/// Each line prints p50, p99 and max in microseconds of thread CPU time and of wall time, with n.
@Suite(
    "Benchmark", .serialized, .enabled(if: ProcessInfo.processInfo.environment["EMOJI_BENCHMARK"] == "1"),
    .timeLimit(.minutes(5)))
struct Benchmark {
    /// Budget: 100 µs per keystroke on the main thread.
    @Test func colonSearchKeystrokes() async throws {
        let fakes = FakeServices()
        for (index, entry) in bundledCatalog.entries.enumerated() where index % 40 == 0 {
            fakes.usage.recordUse(of: ItemID(EmojiLibrary.namespace, entry.key))
        }
        let harness = await loadedHarness(fakes)
        let provider = harness.feature.colonSearch
        let words = [
            "smile", "heart", "thumbs up", "cat", "rocket", "fire", "laugh", "party", "check", "arrow", "flag united",
            "face with tears", "co", "sm", "hand", "euro", "command", "zzzz",
        ]
        var cpu: [Double] = []
        var wall: [Double] = []
        for round in 0..<40 {
            for word in words {
                // Typed one character at a time, as root calls it.
                var query = ""
                for character in ":" + word {
                    query.append(character)
                    let start = Self.threadNanoseconds()
                    let began = ContinuousClock.now
                    let answer = provider.answer(for: query)
                    let elapsed = ContinuousClock.now - began
                    let used = Self.threadNanoseconds() - start
                    if round > 0 {
                        cpu.append(Double(used) / 1_000)
                        wall.append(Self.microseconds(elapsed))
                    }
                    withExtendedLifetime(answer) {}
                }
            }
        }
        Self.report("colon search, per keystroke", cpu: cpu, wall: wall)
        // A foreign query is rejected on its first byte.
        var foreign: [Double] = []
        for _ in 0..<2_000 {
            let start = Self.threadNanoseconds()
            _ = provider.answer(for: "safari")
            foreign.append(Double(Self.threadNanoseconds() - start) / 1_000)
        }
        Self.report("colon search, foreign query", cpu: foreign, wall: [])
        #expect(Self.percentile(cpu, 0.99) < 100)
    }

    /// The worst queries within the caps: many one-letter words, each of which starts thousands of
    /// terms, typed one character at a time, and the longest text the provider reads.
    @Test func colonSearchWorstCase() async throws {
        let harness = await loadedHarness()
        let provider = harness.feature.colonSearch
        let queries = [
            "a b c d e f g h i j", "s m", "a a a a a a a a a a", "t u v w", String(repeating: "x", count: 64),
        ]
        var cpu: [Double] = []
        for round in 0..<20 {
            for text in queries {
                var query = ""
                for character in ":" + text {
                    query.append(character)
                    let start = Self.threadNanoseconds()
                    let answer = provider.answer(for: query)
                    let used = Self.threadNanoseconds() - start
                    if round > 0 { cpu.append(Double(used) / 1_000) }
                    withExtendedLifetime(answer) {}
                }
            }
        }
        Self.report("colon search, worst queries per keystroke", cpu: cpu, wall: [])
        #expect(Self.percentile(cpu, 0.99) < 100)
    }

    /// Budget: the grid's data for about 4,000 entries in under 20 ms off the main thread.
    @Test func gridData() async throws {
        let recent = bundledCatalog.entries.prefix(16).map(\.key)
        var frecency: [ItemID: Double] = [:]
        for (index, entry) in bundledCatalog.entries.enumerated() where index % 40 == 0 {
            frecency[ItemID(EmojiLibrary.namespace, entry.key)] = Double(index % 7)
        }
        let options = EmojiRows.Options(tone: .medium, includeSymbols: true, recentKeys: recent, frecency: frecency)

        // Every skin tone variant as an entry of its own: about 4,300 entries.
        let expanded = EmojiCatalog(
            entries: bundledCatalog.entries.flatMap { entry in
                [entry]
                    + entry.variants.enumerated().map { index, variant in
                        EmojiEntry(
                            glyph: variant, name: "\(entry.name) \(index)", group: entry.group,
                            version: entry.version, keywords: entry.keywords)
                    }
            })
        for (name, catalog) in [("grid data, bundled catalog", bundledCatalog), ("grid data, expanded", expanded)] {
            var cpu: [Double] = []
            var wall: [Double] = []
            var rows = 0
            for round in 0..<201 {
                let result = await Self.measureOffMain { EmojiRows.build(catalog, options) }
                rows = result.value.reduce(0) { $0 + $1.rows.count }
                if round > 0 {
                    cpu.append(result.cpu)
                    wall.append(result.wall)
                }
            }
            Self.report("\(name), \(catalog.entries.count) entries, \(rows) rows", cpu: cpu, wall: wall)
            #expect(Self.percentile(cpu, 0.99) < 20_000)
        }
    }

    /// Off the main thread at activation: parse the data and build the colon index.
    @Test func loading() async throws {
        var cpu: [Double] = []
        var wall: [Double] = []
        for round in 0..<31 {
            let result = await Self.measureOffMain { try? EmojiCatalog.parse(EmojiData.text) }
            let index = await Self.measureOffMain { result.value.map(ColonIndex.init(catalog:)) }
            if round > 0 {
                cpu.append(result.cpu + index.cpu)
                wall.append(result.wall + index.wall)
            }
        }
        Self.report("load: parse and colon index", cpu: cpu, wall: wall)
    }

    /// Inside an interaction on the main thread: the actions for a selected cell.
    @Test func actions() async throws {
        let harness = await loadedHarness()
        let rows = bundledCatalog.entries.enumerated().filter { $0.offset % 5 == 0 }.map {
            EmojiRows.row($0.element, tone: .medium)
        }
        var cpu: [Double] = []
        for row in rows + rows {
            let start = Self.threadNanoseconds()
            let actions = harness.feature.grid.actions(for: row)
            cpu.append(Double(Self.threadNanoseconds() - start) / 1_000)
            withExtendedLifetime(actions) {}
        }
        Self.report("actions(for:)", cpu: cpu, wall: [])
    }

    // MARK: Measuring

    private struct Measured<Value: Sendable>: Sendable {
        let value: Value
        let cpu: Double
        let wall: Double
    }

    @concurrent private static func measureOffMain<Value: Sendable>(_ work: @Sendable () -> Value) async -> Measured<
        Value
    > {
        let start = threadNanoseconds()
        let began = ContinuousClock.now
        let value = work()
        let elapsed = ContinuousClock.now - began
        return Measured(value: value, cpu: Double(threadNanoseconds() - start) / 1_000, wall: microseconds(elapsed))
    }

    nonisolated private static func threadNanoseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    }

    nonisolated private static func microseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000_000 + Double(duration.components.attoseconds) / 1e12
    }

    nonisolated private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
    }

    private static func report(_ name: String, cpu: [Double], wall: [Double]) {
        func line(_ values: [Double]) -> String {
            guard !values.isEmpty else { return "-" }
            let p50 = percentile(values, 0.5)
            let p99 = percentile(values, 0.99)
            let maximum = values.max() ?? 0
            return String(format: "p50 %.1f p99 %.1f max %.1f", p50, p99, maximum)
        }
        var load = [0.0, 0.0, 0.0]
        getloadavg(&load, 3)
        print(
            "BENCH \(name): n=\(cpu.count) cpu µs [\(line(cpu))] wall µs [\(line(wall))] load \(String(format: "%.1f", load[0]))"
        )
    }
}
