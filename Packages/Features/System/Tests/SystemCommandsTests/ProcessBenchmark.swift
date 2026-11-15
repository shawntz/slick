import Foundation
import Kit
import KitTesting
import Testing

@testable import SystemCommands

/// Costs of the Kill Process page, measured only when `SYSTEM_BENCHMARK=1`. It prints counts and
/// times only. With `SYSTEM_LIVE_SAMPLE=1` it also times the live process sampler, which reads the
/// user's process table and changes nothing; no name or path is printed.
@Suite(
    "Kill Process benchmark", .serialized, .timeLimit(.minutes(5)),
    .enabled(if: ProcessInfo.processInfo.environment["SYSTEM_BENCHMARK"] == "1"))
@MainActor
struct ProcessBenchmark {
    static let processCount = 600

    static func snapshot(_ step: UInt64) -> ProcessSnapshot {
        let processes = (0..<processCount).map { index in
            var sample = SimulatedProcessTable.sample(
                Int32(1_000 + index), "example-process-\(index)",
                app: index % 10 == 0 ? "com.example.app\(index)" : nil,
                memory: UInt64(index % 97) << 20)
            sample.cpuTime = step * UInt64(index % 13) * 10_000_000
            return sample
        }
        return ProcessSnapshot(uptime: step * 1_000_000_000, ownPID: 99, processes: processes)
    }

    static func report(_ label: String, _ samples: [Duration]) {
        let sorted = samples.sorted()
        func milliseconds(_ duration: Duration) -> String {
            let (seconds, attoseconds) = duration.components
            return String(format: "%.3f ms", Double(seconds) * 1_000 + Double(attoseconds) / 1e15)
        }
        let p50 = sorted[sorted.count / 2]
        let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
        print("BENCH \(label): n=\(sorted.count) p50=\(milliseconds(p50)) p99=\(milliseconds(p99))")
    }

    @Test func buildingRowsOffTheMainThread() async {
        let clock = ContinuousClock()
        var samples: [Duration] = []
        let locale = Locale(identifier: "en_US")
        for step in 1...200 {
            let previous = Self.snapshot(UInt64(step))
            let now = Self.snapshot(UInt64(step + 1))
            let start = clock.now
            let rows = await ProcessRows.rows(
                now, previous: previous, sort: .cpu, showsBackground: true, locale: locale)
            samples.append(clock.now - start)
            #expect(rows.count == Self.processCount)
        }
        Self.report("rows for \(Self.processCount) processes, off main", samples)
    }

    @Test func actionsForARowOnTheMainThread() async throws {
        let table = SimulatedProcessTable(Self.snapshot(1).processes)
        let list = ProcessList(
            table: table, settings: FakeServices().context(featureID: "system").settings, locale: .current)
        let rows = try await list.load(ListRequest()).sections.flatMap(\.rows)
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for _ in 0..<5 {
            for row in rows {
                let start = clock.now
                let actions = list.actions(for: row)
                samples.append(clock.now - start)
                #expect(actions.count == 5)
            }
        }
        Self.report("actions(for:) per row, main thread", samples)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SYSTEM_LIVE_SAMPLE"] == "1"))
    func liveSamplerReadsTheProcessTable() async throws {
        let table = LiveProcessTable()
        let clock = ContinuousClock()
        var samples: [Duration] = []
        var counts: [Int] = []
        for _ in 0..<50 {
            let start = clock.now
            let snapshot = try await table.snapshot()
            samples.append(clock.now - start)
            counts.append(snapshot.processes.count)
        }
        print("BENCH live sampler process count: min=\(counts.min() ?? 0) max=\(counts.max() ?? 0)")
        Self.report("live snapshot, off main", samples)
    }
}
