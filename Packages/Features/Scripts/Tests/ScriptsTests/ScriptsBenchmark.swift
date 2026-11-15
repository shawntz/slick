import Foundation
import Kit
import KitTesting
import Testing

@testable import Scripts

/// Timings for the paths that run often. Off by default; run with `SCRIPTS_BENCHMARK=1`, in a
/// release build, one suite at a time. Prints counts and milliseconds only.
@Suite(
    "Benchmark", .serialized, .timeLimit(.minutes(5)),
    .enabled(if: ProcessInfo.processInfo.environment["SCRIPTS_BENCHMARK"] == "1"))
@MainActor
struct ScriptsBenchmark {
    /// CPU time of the calling thread, in milliseconds.
    private static func threadMilliseconds() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) * 1000 + Double(time.tv_nsec) / 1_000_000
    }

    private static func report(_ name: String, _ samples: [Double], unit: String = "ms") {
        let sorted = samples.sorted()
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let line = String(
            format: "BENCH %@: n=%d p50=%.4f p99=%.4f max=%.4f %@", name, sorted.count, percentile(0.5),
            percentile(0.99), sorted.last ?? 0, unit)
        print(line)
    }

    private static func wall(_ body: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now
        try body()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
    }

    private static func header(_ index: Int) -> String {
        Fixture.script(
            index % 5 == 0 ? "inline" : "compact", title: "Script \(index)",
            extra: [
                "refreshTime 1m", "icon 🤖", "packageName Bench", "description A synthetic script.",
                #"argument1 { "type": "text", "placeholder": "query", "optional": true }"#,
            ], body: String(repeating: "echo line\n", count: 40))
    }

    @Test func headerParsing() {
        let headers = (0..<2000).map(Self.header)
        var samples: [Double] = []
        for header in headers { samples.append(Self.wall { _ = HeaderParser.parse(header) }) }
        Self.report("header parse, one script", samples)
    }

    @Test func catalogOfTwoHundredScripts() {
        let folder = URL(filePath: "/bench", directoryHint: .isDirectory)
        let files = (0..<200).map { ScriptFile(url: folder.appending(path: "s\($0).sh"), header: Self.header($0)) }
        let listing = [FolderListing(folder: folder, exists: true, files: files)]
        let folders = [ScriptFolder(url: folder, isDefault: true, isEnabled: true)]
        var samples: [Double] = []
        for _ in 0..<50 { samples.append(Self.wall { _ = ScriptCatalog.make(listing, folders: folders) }) }
        Self.report("catalog build, 200 scripts", samples)
    }

    @Test func commandsForTwoHundredScripts() async {
        let files = Dictionary(uniqueKeysWithValues: (0..<200).map { ("s\($0).sh", Self.header($0)) })
        let bench = ScriptsBench(files: files)
        await bench.start()
        #expect(bench.scriptCommands.count == 200)
        var samples: [Double] = []
        for _ in 0..<50 {
            let start = Self.threadMilliseconds()
            _ = bench.feature.commands
            samples.append(Self.threadMilliseconds() - start)
        }
        Self.report("commands read on the main thread, 204 commands, CPU", samples)
    }

    @Test func listOutputOfAThousandItems() throws {
        let items = (0..<1000).map { index in
            #"{"uid": "\#(index)", "title": "Result \#(index)", "subtitle": "Subtitle \#(index)", "arg": "https://example.com/\#(index)", "mods": {"cmd": {"arg": "\#(index)", "subtitle": "Copy"}}, "variables": {"n": "\#(index)"}}"#
        }
        let data = Data(#"{"rerun": 1, "items": [\#(items.joined(separator: ","))]}"#.utf8)
        let source = FilterOutput.Source(
            namespace: "scripts", commandID: "script.bench", folder: URL(filePath: "/bench"),
            home: URL(filePath: "/home"), query: "result")
        var samples: [Double] = []
        for _ in 0..<50 { samples.append(try Self.wall { _ = try FilterOutput.page(from: data, source: source) }) }
        Self.report("list JSON parse, 1000 items, \(data.count / 1024) KB", samples)
    }

    @Test func listRowActions() async throws {
        let items = (0..<1000).map { index in
            #"{"uid": "\#(index)", "title": "Result \#(index)", "arg": "https://example.com/\#(index)", "mods": {"cmd": {"arg": "\#(index)"}, "alt": {"arg": "x"}}, "text": {"copy": "c"}}"#
        }
        let json = #"{"items": [\#(items.joined(separator: ","))]}"#
        let bench = ScriptsBench(files: ["list.sh": Fixture.script("list")])
        bench.fakes.processes.stubScripts { _ in .stdout(json) }
        await bench.start()
        try await bench.harness.run(bench.id("list.sh"))
        guard case .list(let page) = bench.harness.page?.page else {
            Issue.record("expected a list")
            return
        }
        var samples: [Double] = []
        for row in bench.harness.rows {
            let start = Self.threadMilliseconds()
            _ = page.source.actions(for: row)
            samples.append(Self.threadMilliseconds() - start)
        }
        Self.report("list row actions on the main thread, CPU", samples)
    }
}
