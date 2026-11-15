import CoreBridge
import Darwin
import Foundation
import Kit
import KitTesting
import Synchronization
import Testing

@testable import Calc

/// Measures the provider's budgets through CoreBridge. Opt in with `CALC_BENCHMARK=1`, in a release
/// build:
///
///     CALC_BENCHMARK=1 scripts/swiftpm.sh Packages/Features/Calc test -c release \
///         -Xswiftc -enable-testing --filter Benchmark
///
/// Each line prints n, p50, p99 and max in microseconds of thread CPU time, and the load average.
@Suite(
    "Benchmark", .serialized, .enabled(if: ProcessInfo.processInfo.environment["CALC_BENCHMARK"] == "1"),
    .timeLimit(.minutes(5)))
struct Benchmark {
    static let answered = [
        "2 + 2", "12 * 3", "1/3", "sqrt(2)", "2^100", "15% of 80", "30 is what % of 120", "10 kg in lbs",
        "5 ft 11 in in cm", "180 cm in feet and inches", "100 usd in eur", "2h 30m + 45m", "today + 3 weeks",
        "time in tokyo", "3pm london in tokyo", "days until christmas", "1234 in words", "0xff", "1.75 as fraction",
        "now in unix", "１２ * ３", "١٢+٣",
    ]
    static let rejected = [
        "safari", "Visual Studio Code", "terminal", "system settings", "google chrome", "activity monitor",
        "notes 2024", "1password", "iphone 15 pro", "hello world", "clipboard history", "window", "s", "sa",
        "こんにちは", "Ｓａｆａｒｉ", "café",
    ]

    /// Budget: the provider's answer in under 100 µs at p99, from query to row.
    @Test func answers() async throws {
        let harness = await readyHarness(rates: ScriptedRates(saved: sampleTable()))
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
                // Typed one character at a time, as root calls it.
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
    }

    /// Budget: a rejected query in under 1 µs at p50, with no allocation. Rejects sit below the CPU
    /// clock's resolution, so they are timed in batches of 256 and divided.
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

        // The counter sees an allocation, so a zero below means none happened.
        let control = AllocationCounter.count { AllocationCounter.allocateOnce() }
        #expect(control >= 1)
        // Allocations on this thread while rejecting, native and bridged strings alike.
        let queries = Self.rejected + bridged
        for query in queries { _ = provider.answer(for: query) }
        let allocations = AllocationCounter.count {
            for _ in 0..<100 {
                for query in queries { _ = provider.answer(for: query) }
            }
        }
        let calls = 100 * queries.count
        print("BENCH reject, allocations: \(allocations) in \(calls) calls")
        #expect(allocations == 0)
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
/// one MallocStackLogging uses. Tests only.
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
