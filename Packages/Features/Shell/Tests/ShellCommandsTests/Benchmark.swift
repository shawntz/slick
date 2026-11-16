import Darwin
import Foundation
import Kit
import Testing

@testable import ShellCommands

/// Measures what runs inside a keystroke and what runs per chunk of output. Opt in with
/// `SHELL_BENCHMARK=1`, in a release build:
///
///     SHELL_BENCHMARK=1 scripts/swiftpm.sh Packages/Features/Shell test -c release \
///         -Xswiftc -enable-testing --filter Benchmark
///
/// Each line prints n, p50, p99 and max in microseconds of thread CPU time, and the load average.
@Suite(
    "Benchmark", .serialized, .enabled(if: ProcessInfo.processInfo.environment["SHELL_BENCHMARK"] == "1"),
    .timeLimit(.minutes(5)))
struct Benchmark {
    /// Budget: `takesOver` is asked on every keystroke for every query, as cheap as an instant
    /// provider, 100 µs at p99, whatever the query.
    @Test func takesOverStaysWithinTheInstantBudget() {
        let queries = [
            "safari", "Visual Studio Code", "s", "こんにちは", String(repeating: "pasted text ", count: 80_000),
            "> ls -la", ">" + String(repeating: " ", count: 1023) + "x", ">" + String(repeating: " ", count: 5000),
        ]
        var costs: [Double] = []
        for round in 0..<200 {
            for query in queries {
                let cost = Self.cpu { RootQuery.claims(query) }
                if round > 0 { costs.append(cost) }
            }
        }
        Self.report("takesOver", costs)
        #expect(Self.percentile(costs, 0.99) < 100)
    }

    /// The work per chunk of output off the main thread: the buffer append, with the trims past the
    /// limit, over 64 MB in 16 KB chunks against the 2 MB default.
    @Test func appendingOutputStaysCheapPastTheLimit() {
        var buffer = OutputBuffer(limit: OutputLimit.twoMegabytes.bytes)
        let chunk = String(repeating: String(repeating: "x", count: 63) + "\n", count: 256)
        var costs: [Double] = []
        for _ in 0..<4096 {
            costs.append(Self.cpu { buffer.append(chunk) })
        }
        Self.report("append 16 KB", costs)
        #expect(buffer.count <= OutputLimit.twoMegabytes.bytes)
        #expect(Self.percentile(costs, 0.5) < 100)
    }

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
