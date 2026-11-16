import Darwin
import Foundation
import Kit
import KitTesting
import Synchronization
import Testing

@testable import ColorTools

/// Measures the provider's budget and the history page at scale. Opt in with `COLORS_BENCHMARK=1`,
/// in a release build:
///
///     COLORS_BENCHMARK=1 scripts/swiftpm.sh Packages/Features/Colors test -c release \
///         -Xswiftc -enable-testing --filter Benchmark
///
/// Each line prints n, p50, p99 and max in microseconds of thread CPU time, and the load average.
@Suite(
    "Benchmark", .serialized, .enabled(if: ProcessInfo.processInfo.environment["COLORS_BENCHMARK"] == "1"),
    .timeLimit(.minutes(5)))
struct Benchmark {
    static let answered = [
        "#639", "#663399", "#66339980", "rgb(102, 51, 153)", "rgb(102 51 153 / 50%)", "hsl(270 50% 40%)",
        "hsla(270, 50%, 40%, 0.5)", "hwb(270 20% 40%)", "oklch(44.03% 0.1603 303.37)", "color rebeccapurple",
        "color lightgoldenrodyellow", "contrast #767676 #fff", "contrast rgb(0 0 0) on hsl(0 0% 100%)",
    ]
    static let rejected = [
        "safari", "Visual Studio Code", "terminal", "system settings", "google chrome", "calendar", "chrome",
        "code", "hello world", "clipboard history", "contacts", "notes 2024", "1password", "こんにちは",
        "Ｓａｆａｒｉ", "café", "rgb", "colour", "contrasts",
    ]

    /// Budget: the provider's answer in under 100 µs at p99, from query to row.
    @Test func answers() async throws {
        let harness = await readyHarness()
        let provider = harness.feature.provider
        for query in Self.answered {
            #expect(provider.answer(for: query) != nil, "\(query)")
        }
        var whole: [Double] = []
        var typed: [Double] = []
        for round in 0..<60 {
            for query in Self.answered {
                let used = Self.cpu { provider.answer(for: query) }
                if round > 0 { whole.append(used) }
                var prefix = ""
                for character in query {
                    prefix.append(character)
                    let cost = Self.cpu { provider.answer(for: prefix) }
                    if round > 0 { typed.append(cost) }
                }
            }
        }
        Self.report("answer, whole queries", whole)
        Self.report("answer, every keystroke while typing", typed)
        #expect(Self.percentile(whole, 0.99) < 100)
        #expect(Self.percentile(typed, 0.99) < 100)

        // A long paste that starts like a color.
        let pasted = "rgb(" + String(repeating: "1 ", count: 50_000) + ")"
        var paste: [Double] = []
        for _ in 0..<200 { paste.append(Self.cpu { provider.answer(for: pasted) }) }
        Self.report("answer, 100 KB paste that starts like a color", paste)
        #expect(Self.percentile(paste, 0.99) < 100)
    }

    /// Budget: a rejected query in under 1 µs at p50, with no allocation.
    @Test func rejects() async throws {
        let harness = await readyHarness()
        let provider = harness.feature.provider
        let bridged = Self.rejected.map { NSMutableString(string: $0) as String }
        for query in Self.rejected + bridged {
            #expect(provider.answer(for: query) == nil, "\(query)")
        }
        var perCall: [Double] = []
        for _ in 0..<200 {
            for query in Self.rejected {
                let batch = Self.cpu {
                    for _ in 0..<256 { _ = provider.answer(for: query) }
                }
                perCall.append(batch / 256)
            }
        }
        Self.report("reject, per call", perCall)
        #expect(Self.percentile(perCall, 0.5) < 1)

        let control = AllocationCounter.count { AllocationCounter.allocateOnce() }
        #expect(control >= 1)
        let queries = Self.rejected + bridged
        for query in queries { _ = provider.answer(for: query) }
        let allocations = AllocationCounter.count {
            for _ in 0..<100 {
                for query in queries { _ = provider.answer(for: query) }
            }
        }
        print("BENCH reject, allocations: \(allocations) in \(100 * queries.count) calls")
        #expect(allocations == 0)
    }

    /// The history page's rows for 1,000 and 50,000 colors, built off the main thread, and the
    /// action panel on one of them.
    @Test func historyAtScale() async throws {
        let clock = FakeClock()
        for count in [1_000, 50_000] {
            let entries = (0..<count).map { index in
                ColorEntry(
                    color: ColorValue(bytes: index % 256, index / 256 % 256, index / 65_536 % 256),
                    isPinned: index % 500 == 0, date: clock.now.addingTimeInterval(-Double(index) * 60),
                    source: .picked)
            }
            var times: [Double] = []
            for _ in 0..<5 {
                times.append(
                    Self.cpu { HistoryList.build(entries, formatter: ColorFormatter(), format: .hex, clock: clock) })
            }
            Self.report("history rows, \(count) colors", times)
        }

        let harness = await readyHarness()
        for index in 0..<1_000 {
            await harness.feature.history.add(ColorValue(bytes: index % 256, index / 256, 7), source: .picked)
        }
        try await harness.run("history")
        let row = try #require(harness.rows.last)
        var actions: [Double] = []
        for _ in 0..<500 { actions.append(Self.cpu { harness.feature.historyList.actions(for: row) }) }
        Self.report("actions(for:) on a history of 1,000", actions)
        #expect(Self.percentile(actions, 0.99) < 8_000)
    }

    // MARK: Measuring

    private static func cpu<Value>(_ work: () -> Value) -> Double {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let value = work()
        let used = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start
        withExtendedLifetime(value) {}
        return Double(used) / 1_000
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
    }

    private static func report(_ name: String, _ values: [Double]) {
        var load = [0.0, 0.0, 0.0]
        getloadavg(&load, 3)
        let line = String(
            format: "n=%d p50 %.3f p99 %.3f max %.3f µs, load %.2f", values.count, percentile(values, 0.5),
            percentile(values, 0.99), values.max() ?? 0, load[0])
        print("BENCH \(name): \(line)")
    }
}

/// Counts heap allocations made by the calling thread through libmalloc's `malloc_logger` hook, the
/// one MallocStackLogging uses. Tests only. The same counter as Calc's benchmark.
enum AllocationCounter {
    private typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    static func count(_ work: () -> Void) -> UInt64 {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return .max }
        let slot = symbol.assumingMemoryBound(to: Logger?.self)
        allocationCount.store(0, ordering: .sequentiallyConsistent)
        countedThread.store(UInt(bitPattern: pthread_self()), ordering: .sequentiallyConsistent)
        slot.pointee = countAllocation
        work()
        slot.pointee = nil
        return allocationCount.load(ordering: .sequentiallyConsistent)
    }

    /// Allocates and frees one block in a way the optimizer cannot remove.
    @inline(never) static func allocateOnce() {
        let block = malloc(64)
        lastBlock.store(UInt(bitPattern: block), ordering: .sequentiallyConsistent)
        free(block)
    }
}

private nonisolated let lastBlock = Atomic<UInt>(0)

private nonisolated let allocationCount = Atomic<UInt64>(0)
private nonisolated let countedThread = Atomic<UInt>(0)

/// Called by libmalloc for every allocation on every thread while installed. It must not allocate.
private nonisolated func countAllocation(
    type: UInt32, arg1: UInt, arg2: UInt, arg3: UInt, result: UInt, skip: UInt32
) {
    // MALLOC_LOG_TYPE_ALLOCATE
    guard type & 2 != 0, UInt(bitPattern: pthread_self()) == countedThread.load(ordering: .relaxed) else { return }
    allocationCount.add(1, ordering: .relaxed)
}
