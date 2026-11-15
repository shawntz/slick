// Engine latency as Swift sees it, through CoreBridge, against the budgets in docs/ARCHITECTURE.md:
// a query (ranking and top 50 included) under 300 µs at p99 over 3,000 items and under 1 ms over
// 10,000 items, zero heap allocations per query including the String to UTF-8 step, suggestions
// under 50 µs and recording an execution under 100 µs. Exits with status 1 when a budget is blown.
//
// The calculator and the file index have their own sections, in CalculatorBench.swift and
// FileIndexBench.swift.
//
// Run with `make bench-core`, or `swift run -c release --package-path Packages/CoreBridge corebridge-bench`.
// Set REPS to change the number of repetitions, and BENCH_ONLY to engine, calc or files to run one
// section. BENCH_QOS=background runs at the background QoS
// class, which macOS keeps on the efficiency cores: the slowest case, and the one the budgets
// are stated for.
import BenchSupport
import CoreBridge
import Foundation

let reps = Int(ProcessInfo.processInfo.environment["REPS"] ?? "") ?? 30
let only = ProcessInfo.processInfo.environment["BENCH_ONLY"]

let verbs = ["Search", "Create", "Open", "Toggle", "Show", "Copy", "Manage", "List", "Start", "Stop", "Add", "Delete"]
let services = [
    "Asana", "Trello", "GitHub", "Linear", "Notion", "Spotify", "Docker", "Figma", "Slack", "Zoom", "Dropbox", "Stripe",
    "Sentry", "Grafana", "Netlify", "Vercel", "Postman", "Discord", "YouTube Music", "Café Crème",
]
let nouns = [
    "Issues", "Tasks", "Notes", "Pages", "Files", "Projects", "Bookmarks", "Tabs", "Repos", "Branches", "Commits",
    "Deployments", "Builds", "Logs", "Secrets", "Domains", "Invoices", "Orders", "Events", "Meetings", "Playlists",
]
let apps = [
    "Safari", "Mail", "Calendar", "Notes", "Music", "Photos", "Messages", "Maps", "Terminal", "Preview",
    "System Settings", "Activity Monitor", "Disk Utility", "Font Book", "Keychain Access", "TextEdit", "Calculator",
]
let queries = [
    "s", "sa", "saf", "t", "te", "ter", "term", "c", "cl", "w", "vsc", "ss", "gc", "tdm", "fari", "ode", "sfari",
    "termnial", "mode dark", "vs code", "search goo", "system set", "café", "issue", "github iss", "create", "open",
    "a", "e", "dash", "spot", "musi", "zoom meet", "logs", "x", "ma",
]

func catalog(_ n: Int) -> [CatalogItem] {
    (0..<n).map { i in
        if i < apps.count {
            return CatalogItem(key: ItemKey(id: "app:\(apps[i])"), title: apps[i], kind: .app)
        }
        let v = verbs[i % verbs.count]
        let s = services[(i / verbs.count) % services.count]
        let noun = nouns[(i / (verbs.count * services.count)) % nouns.count]
        let title = i % 2 == 0 ? "\(v) \(s) \(noun)" : "\(s): \(v) \(noun) \(i % 97)"
        return CatalogItem(key: ItemKey(id: "cmd:synthetic.\(i)"), title: title, kind: .command)
    }
}

struct Samples {
    let name: String
    var micros: [Double] = []
    let budget: Double?

    @discardableResult
    mutating func time<R>(_ body: () throws -> R) rethrows -> R {
        let t = bench_now_ns()
        let r = try body()
        micros.append(Double(bench_now_ns() - t) / 1_000)
        return r
    }

    func quantile(_ q: Double) -> Double {
        let s = micros.sorted()
        return s[Int((Double(s.count - 1) * q).rounded())]
    }

    /// Prints a table row; returns false when the p99 is over budget.
    func report() -> Bool {
        let p99 = quantile(0.99)
        let ok = budget.map { p99 < $0 } ?? true
        let verdict = budget.map { ok ? "< \(Int($0)) ok" : "< \(Int($0)) OVER" } ?? "-"
        // Sub-microsecond rows need more digits than the rest.
        let format = p99 < 10 ? "%8.3f" : "%8.1f"
        let cells = [quantile(0), quantile(0.5), p99, quantile(1)].map { String(format: format, $0) }
        print(
            "| \(name.padding(toLength: 44, withPad: " ", startingAt: 0)) | \(micros.count) | \(cells.joined(separator: " | ")) | \(verdict) |"
        )
        return ok
    }
}

/// An engine over `n` synthetic items with a learning history of 2,000 executions over 400 items.
/// Returns it with the time of the last execution.
func trainedEngine(_ n: Int) throws -> (Engine, [CatalogItem], Double) {
    let items = catalog(n)
    let engine = try Engine()
    try engine.replaceSource(1, with: items)
    var now = 1_780_000_000.0
    try engine.setContext(EngineContext(now: now, hour: 9, weekday: 1))
    for k in 0..<2_000 {
        now += 600
        let item = items[(k * 7_919) % 400]
        let typed = String(item.title.prefix(1 + k % 4))
        try engine.recordExecution(of: item.key, query: typed, source: .typed, at: now)
    }
    return (engine, items, now)
}

/// Full-scan and typing latency over `engine`. Returns false when a budget is blown.
func measureQueries(_ engine: Engine, items n: Int, buffer: QueryBuffer, sink: inout Int) throws -> Bool {
    let budget: Double = n <= 3_000 ? 300 : 1_000
    var full = Samples(name: "query (String), full scan, top 50, \(n) items", budget: budget)
    for _ in 0..<reps {
        for q in queries {
            buffer.reset()
            sink &+= try full.time { try engine.query(q, into: buffer) }
        }
    }
    var typing = Samples(name: "query (String), typed char by char, \(n) items", budget: budget)
    for _ in 0..<reps {
        for q in queries {
            buffer.reset()
            var typed = ""
            for c in q {
                typed.append(c)
                sink &+= try typing.time { try engine.query(typed, into: buffer) }
            }
        }
    }
    let fullOK = full.report()
    let typingOK = typing.report()
    return fullOK && typingOK
}

func run() throws {
    if ProcessInfo.processInfo.environment["BENCH_QOS"] == "background" {
        pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0)
    }
    var ok = true
    var sink = 0
    print("| case | n | min µs | p50 µs | p99 µs | max µs | budget p99 |")
    print("|---|---|---|---|---|---|---|")
    if only == nil || only == "calc" {
        ok = try measureCalculator(sink: &sink) && ok
    }
    if only == nil || only == "files" {
        ok = try measureFiles(sink: &sink) && ok
    }
    if only == nil || only == "engine" {
        ok = try measureEngine(sink: &sink) && ok
    }
    print("\n(sink \(sink & 1))")
    if !ok {
        FileHandle.standardError.write(Data("a latency or allocation budget was blown\n".utf8))
        exit(1)
    }
}

/// The engine: 3,000 and 10,000 items with 2,000 learned executions. Returns false when a budget
/// is blown.
func measureEngine(sink: inout Int) throws -> Bool {
    let buffer = try QueryBuffer(capacity: 50)
    var ok = true
    print("engine: 3,000 and 10,000 items, 2,000 learned executions, reps \(reps)")

    // One FFI call is far below a microsecond, so this row reports nanoseconds per call.
    var noop = Samples(name: "FFI no-op, ns per call (batches of 10,000)", budget: nil)
    for _ in 0..<reps {
        noop.time { for _ in 0..<10_000 { try? RustCore.noop() } }
    }
    noop.micros = noop.micros.map { $0 * 1_000 / 10_000 }
    _ = noop.report()

    let (small, _, _) = try trainedEngine(3_000)
    ok = try measureQueries(small, items: 3_000, buffer: buffer, sink: &sink) && ok
    let (engine, items, last) = try trainedEngine(10_000)
    var now = last
    ok = try measureQueries(engine, items: 10_000, buffer: buffer, sink: &sink) && ok

    var suggest = Samples(name: "suggestions: context change, recompute", budget: 50)
    for k in 0..<(reps * 30) {
        let context = EngineContext(
            now: now + Double(k), hour: UInt8(k % 24), weekday: UInt8(k % 7), frontmost: items[k % 17].key)
        try suggest.time { try engine.setContext(context) }
    }
    ok = suggest.report() && ok

    var record = Samples(name: "record an execution", budget: 100)
    for k in 0..<(reps * 30) {
        now += 30
        let item = items[(k * 104_729) % 3_000]
        try record.time { try engine.recordExecution(of: item.key, query: "abc", source: .typed, at: now) }
    }
    ok = record.report() && ok

    // Allocations per query, String to UTF-8 included: native, bridged and non-ASCII strings.
    let bridged = NSMutableString(string: "system ")
    bridged.append("set")
    let inputs: [(String, String)] = [
        ("native", "term"), ("bridged NSString", bridged as String), ("non-ASCII", "café crème"),
    ]
    for (label, text) in inputs {
        for _ in 0..<3 { try engine.query(text, into: buffer) }
        bench_alloc_count_begin()
        for _ in 0..<1_000 { sink &+= try engine.query(text, into: buffer) }
        let allocations = bench_alloc_count_end()
        let perQuery = Double(allocations) / 1_000
        print("allocations per query, \(label) string: \(String(format: "%.2f", perQuery))")
        ok = ok && allocations == 0
    }
    return ok
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("bench failed: \(error)\n".utf8))
    exit(1)
}
