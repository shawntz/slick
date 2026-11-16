import Darwin
import Foundation
import Kit
import KitTesting
import Synchronization
import Testing

@testable import TranslateCommands

/// Measures the keyword provider inside the keystroke. Opt in with `TRANSLATE_BENCHMARK=1`, in a
/// release build:
///
///     TRANSLATE_BENCHMARK=1 scripts/swiftpm.sh Packages/Features/Translate test -c release \
///         -Xswiftc -enable-testing --filter Benchmark
///
/// Each line prints n, p50, p99 and max in microseconds of thread CPU time, and the load average.
@Suite(
    "Benchmark", .serialized, .enabled(if: ProcessInfo.processInfo.environment["TRANSLATE_BENCHMARK"] == "1"),
    .timeLimit(.minutes(5)))
struct Benchmark {
    static let rejected = [
        "safari", "Visual Studio Code", "terminal", "trash", "tr", "translate", "system settings", "t", "te",
        "notes 2024", "こんにちは", "Ｓａｆａｒｉ", "café", "tra", "Text Edit", "translate sel", "Translate Selection",
    ]
    static let keyword = [
        "tr Bonjour", "translate La bouilloire bleue chante", "tr Seven paper boats to Japanese",
        "tr Good morning to english united kingdom", "tr I want to go to the harbour before the tide turns",
        "TR " + String(repeating: "word ", count: 190),
    ]

    /// Budget: a refused query in well under 1 µs, with no allocation.
    @Test func rejects() async throws {
        let harness = await readyHarness(SimulatedTranslation())
        let provider = harness.feature.provider
        let bridged = Self.rejected.map { NSMutableString(string: $0) as String }
        for query in Self.rejected + bridged {
            #expect(provider.answer(for: query) == nil, "\(query)")
        }
        var perCall: [Double] = []
        for _ in 0..<200 {
            for query in Self.rejected + bridged {
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
        let allocations = AllocationCounter.count {
            for _ in 0..<100 {
                for query in queries { _ = provider.answer(for: query) }
            }
        }
        print("BENCH reject, allocations: \(allocations) in \(100 * queries.count) calls")
        #expect(allocations == 0)
    }

    /// Budget: a keyword query, from the query to its row, in under 100 µs at p99, whether the row
    /// says it is translating or shows a finished answer.
    @Test func keywordQueries() async throws {
        let harness = await readyHarness(SimulatedTranslation())
        let provider = harness.feature.provider
        var waiting: [Double] = []
        var typed: [Double] = []
        for round in 0..<40 {
            for query in Self.keyword {
                let used = Self.cpu { provider.answer(for: query) }
                if round > 0 { waiting.append(used) }
                var prefix = ""
                for character in query.prefix(80) {
                    prefix.append(character)
                    let cost = Self.cpu { provider.answer(for: prefix) }
                    if round > 0 { typed.append(cost) }
                }
            }
        }
        provider.stop()
        Self.report("keyword, row while translating", waiting)
        Self.report("keyword, every keystroke while typing", typed)
        #expect(Self.percentile(waiting, 0.99) < 100)
        #expect(Self.percentile(typed, 0.99) < 100)

        // Finished answers, as root search asks again after the signal.
        let answered = ["tr Bonjour", "tr Seven paper boats to Japanese"]
        for query in answered { _ = try await harness.rootAnswer(query) }
        var cached: [Double] = []
        for _ in 0..<2_000 {
            for query in answered {
                cached.append(Self.cpu { provider.answer(for: query) })
            }
        }
        Self.report("keyword, finished answer", cached)
        #expect(Self.percentile(cached, 0.99) < 100)
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
