import CoreBridge
import Darwin
import Foundation
import Kit
import KitTesting
import Testing

@testable import FileSearch

/// Search through the feature on synthetic indexes of 100,000 and 1,000,000 entries, and the
/// index's size on disk and in memory. Opt in with `FILESEARCH_BENCHMARK=1`, in a release build:
///
///     FILESEARCH_BENCHMARK=1 scripts/swiftpm.sh Packages/Features/FileSearch test -c release \
///         -Xswiftc -enable-testing --filter Benchmark
///
/// Each query is typed one character at a time from its second character, as root search sends
/// it. Wall time is from the call to the rows, awaited on the main actor. Main-thread time is the
/// main thread's own CPU time across the same call, which is what a keystroke costs the panel.
@Suite(
    "Benchmark", .serialized, .enabled(if: ProcessInfo.processInfo.environment["FILESEARCH_BENCHMARK"] == "1"),
    .timeLimit(.minutes(10)))
@MainActor
struct Benchmark {
    private static let queries = [
        "report", "invoice", "docs readme", "meeting notes", "project src", "scrennshot", "budget final",
        "thesis chapter", "café", ".pdf", "~/", "~/project",
    ]

    @Test func searchAtOneHundredThousand() async throws {
        try await measure(entries: 100_000, rounds: 5)
    }

    @Test func searchAtOneMillion() async throws {
        try await measure(entries: 1_000_000, rounds: 3)
    }

    @Test func sizeOnDiskAndInMemory() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "\(getpid())0\(Int.random(in: 1...999))")
        defer { try? FileManager.default.removeItem(at: folder) }
        for entries in [100_000, 1_000_000] {
            let index = try FileIndex.synthetic(root: "/synthetic/bench", entries: entries, seed: 3)
            let count = try index.count()
            let heap = try index.snapshot().info.heapBytes
            let file = folder.appending(path: "index-\(entries).bin").path(percentEncoded: false)
            try DiskIndexMaker().save(index, to: file, mark: nil)
            let bytes = try FileManager.default.attributesOfItem(atPath: file)[.size] as? Int ?? 0
            let per = Double(100_000) / Double(count)
            print(
                "BENCH size entries=\(count) disk=\(bytes) bytes (\(Int(Double(bytes) * per)) per 100k) "
                    + "heap=\(heap) bytes (\(Int(Double(heap) * per)) per 100k)")
        }
    }

    private func measure(entries: Int, rounds: Int) async throws {
        let fakes = FakeServices(permissions: .notDetermined)
        let home = Paths.normalized(fakes.storage.homeDirectory.path(percentEncoded: false), home: nil) ?? "/"
        fakes.override(IndexMakerKey.self, with: SyntheticIndexMaker(root: home, entries: entries))
        fakes.override(FileSystemKey.self, with: RecordingFileSystem())
        let harness = FeatureHarness(FileSearchFeature.self, fakes: fakes)
        await harness.activate()
        await harness.feature.waitUntilIdle()
        let count = harness.feature.controller.summary.count
        let provider = harness.feature.rootFiles
        let list = harness.feature.searchList
        var rootWall: [Double] = []
        var rootMain: [Double] = []
        var pageWall: [Double] = []
        var pageMain: [Double] = []
        var rows = 0
        for _ in 0..<rounds {
            for query in Self.queries {
                for length in 2...query.count {
                    let typed = String(query.prefix(length))
                    let (wall, main, found) = try await timed { try await provider.results(for: typed).count }
                    rootWall.append(wall)
                    rootMain.append(main)
                    rows += found
                    let (pageTime, pageCPU, _) = try await timed {
                        try await list.load(ListRequest(query: typed, reason: .query)).sections.count
                    }
                    pageWall.append(pageTime)
                    pageMain.append(pageCPU)
                }
            }
        }
        let load = Self.loadAverage()
        print("BENCH entries=\(count) load=\(load) rows=\(rows)")
        print("BENCH root search wall  \(Self.summary(rootWall))")
        print("BENCH root search main  \(Self.summary(rootMain))")
        print("BENCH page search wall  \(Self.summary(pageWall))")
        print("BENCH page search main  \(Self.summary(pageMain))")
        await harness.deactivate()
    }

    /// Wall time and the main thread's CPU time across one awaited call, in microseconds.
    private func timed(_ work: () async throws -> Int) async throws -> (Double, Double, Int) {
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let wallStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let result = try await work()
        let wallEnd = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let cpuEnd = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        #expect(pthread_main_np() != 0, "measured on the main thread")
        return (Double(wallEnd - wallStart) / 1_000, Double(cpuEnd - cpuStart) / 1_000, result)
    }

    private static func summary(_ samples: [Double]) -> String {
        let sorted = samples.sorted()
        func at(_ q: Double) -> String {
            String(format: "%.1f", sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))])
        }
        return "n=\(sorted.count) p50=\(at(0.5)) p99=\(at(0.99)) max=\(at(1)) µs"
    }

    private static func loadAverage() -> String {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return loads.map { String(format: "%.2f", $0) }.joined(separator: " ")
    }
}
