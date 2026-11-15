import AppKit
import Foundation
import Host
import Kit
import KitHosting
import LauncherUI
@_spi(RootBench) import Root

/// `--bench [name]`: the joined app's latency tables, measured inside the app bundle, with the real
/// root search and the real features over synthetic catalogs of 3,000 and 10,000 items.
///
/// For each catalog size it prints root search's own lines, then Host's bench on the real panel.
/// The 3,000-item catalog runs every Host bench; the 10,000-item catalog runs the ones root search
/// changes: typing, summon and the action panel. The last line is `bench PASS` or `bench FAIL`.
enum BenchMode {
    /// Catalog sizes, smallest first.
    static let sizes = [3_000, 10_000]
    /// Host benches that root search changes, run at every size after the first.
    static let rootSensitive: Set<String> = ["typing", "summon", "actions"]
    /// Every name `--bench` takes.
    static var names: [String] { ["root"] + HostBench.names }

    /// One measured path, printed like Host's table.
    struct Line: Equatable {
        var name: String
        var samples: Int
        var p50: Double
        var p99: Double
        var budgetP99: Double?

        var passed: Bool { budgetP99.map { p99 <= $0 } ?? true }

        var text: String {
            let budget = budgetP99.map { String(format: "- / %.1f", $0) } ?? "- / -"
            let verdict = budgetP99 == nil ? "info" : (passed ? "PASS" : "FAIL")
            return String(format: "%@ | %d | %.3f | %.3f | %@ | %@", name, samples, p50, p99, budget, verdict)
        }
    }

    static func run(only name: String?, folders: RunFolders) async -> Int32 {
        if let name, !names.contains(name) {
            print("bench FAIL: no bench named \(name); the names are \(names.joined(separator: ", "))")
            return 2
        }
        print(String(format: "app bench, 1-minute load average %.2f", loadAverage()))
        var passed = true
        for size in sizes {
            print("")
            print("catalog of \(size) synthetic items")
            let folder = folders.dataRoot.appending(path: "catalog-\(size)", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let assembly = Assembly(
                .init(
                    environment: .bench, dataRoot: folder, rootStorage: .inMemory,
                    builtInSources: [SyntheticCatalog(count: size)]))
            await assembly.start(prewarm: true)
            let root = assembly.root
            guard await SelfTest.within(.seconds(60), { await root.ready() }), root.catalogCount >= size else {
                print("bench FAIL: root search did not load the \(size)-item catalog")
                await assembly.shutdown()
                folders.removeIfTemporary()
                return 1
            }
            print("root catalog holds \(root.catalogCount) items")
            if name == nil || name == "root" {
                let lines = measureRoot(root, size: size)
                print("path | n | p50 ms | p99 ms | budget p50 / p99 ms | verdict")
                for line in lines { print(line.text) }
                passed = lines.allSatisfy(\.passed) && passed
            }
            let hostNames: Set<String>
            if let name {
                hostNames = HostBench.names.contains(name) ? [name] : []
            } else {
                hostNames = size == sizes[0] ? Set(HostBench.names) : rootSensitive
            }
            if !hostNames.isEmpty, let panel = assembly.panel {
                let bench = HostBench(panel: panel)
                // Host prints its own verdict; only the app's last line counts.
                bench.log = { line in
                    guard line != "bench PASS", line != "bench FAIL" else { return }
                    print(line)
                    fflush(stdout)
                }
                passed = await bench.run(hostNames) && passed
            }
            await assembly.shutdown()
        }
        folders.removeIfTemporary()
        print("")
        print(passed ? "bench PASS" : "bench FAIL")
        return passed ? 0 : 1
    }

    // MARK: Root search

    /// Words typed one character at a time, as in Root's own bench.
    static let typingScript = [
        "sample", "sample item", "photo", "note editor", "term", "cal", "studio pro", "ledger", "atl",
        "harbor sync", "zephyr", "budget", "quartz", "orbit", "pdf", "music player", "code", "signal lab",
        "canvas", "report",
    ]

    /// Main-thread CPU of `update(query:)` per keystroke, with the engine query inside it, over
    /// the typing script repeated. Budgets from docs/ARCHITECTURE.md.
    static func measureRoot(_ root: RootSearch, size: Int, rounds: Int = 20) -> [Line] {
        let timings = UpdateTimings(capacity: rounds * 200)
        root.timings = timings
        defer { root.timings = nil }
        var updates: [Double] = []
        var begins: [Double] = []
        for round in 0..<rounds {
            for word in typingScript {
                var start = LatencyClock.threadCPUNanoseconds()
                _ = root.begin()
                let began = LatencyClock.threadCPUNanoseconds()
                if round > 0 { begins.append(Double(began - start) / 1e6) }
                var typed = ""
                for character in word {
                    typed.append(character)
                    start = LatencyClock.threadCPUNanoseconds()
                    _ = root.update(query: typed)
                    let end = LatencyClock.threadCPUNanoseconds()
                    if round > 0 { updates.append(Double(end - start) / 1e6) }
                }
                root.end()
            }
        }
        // The first round warms caches and is left out of both lists.
        let perRound = typingScript.reduce(0) { $0 + $1.count }
        let engine = timings.engineNanos.dropFirst(perRound).map { Double($0) / 1e6 }
        let large = size >= 10_000
        let rootSummary = LatencySummary(updates)
        let engineSummary = LatencySummary(Array(engine))
        let beginSummary = LatencySummary(begins)
        return [
            Line(
                name: "root search update(query:), engine included", samples: rootSummary.count,
                p50: rootSummary.p50, p99: rootSummary.p99, budgetP99: large ? 1.5 : 0.5),
            Line(
                name: "engine query inside it", samples: engineSummary.count, p50: engineSummary.p50,
                p99: engineSummary.p99, budgetP99: large ? 1.0 : 0.3),
            Line(
                name: "root search begin()", samples: beginSummary.count, p50: beginSummary.p50,
                p99: beginSummary.p99, budgetP99: 0.1),
        ]
    }

    static func loadAverage() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) > 0 ? loads[0] : -1
    }
}
