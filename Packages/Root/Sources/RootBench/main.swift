// Root search's synchronous path against its budgets, as main-thread CPU time in a release build:
// update(query:) at most 500 µs p99 with the engine included, begin() at most 100 µs and didRun at
// most 200 µs. The catalog's feature registers three instant providers and two async providers, so
// update(query:) pays for planning, starting and cancelling the async work. It also measures putting
// an async section into the snapshot. It counts heap allocations: none inside the engine call, and
// few in the mapping. Exits with status 1 when a budget is blown.
//
// Run: scripts/swiftpm.sh Packages/Root run -c release root-bench
// REPS sets how often the typing script repeats, 30 by default. PROVIDERS=0 registers only the two
// instant providers of the first version, for comparison.
//
// Efficiency cores: the main queue raises the main thread's QoS again, so asking for background QoS
// from inside the process is not enough. Build once, then run the binary as a background task:
//   taskpolicy -b env BENCH_QOS=background Packages/Root/.build/out/Products/Release/root-bench
// The header line prints the QoS class the main thread reports: 9 is background, 21 the default.
import CoreBridge
import Foundation
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
@_spi(RootBench) import Root
import RootBenchSupport

let reps = Int(ProcessInfo.processInfo.environment["REPS"] ?? "") ?? 30
let withProviders = ProcessInfo.processInfo.environment["PROVIDERS"] != "0"
let qos = ProcessInfo.processInfo.environment["BENCH_QOS"] ?? "default"
if qos == "background" {
    pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0)
}

// MARK: Synthetic catalog

let verbs = ["Search", "Create", "Open", "Toggle", "Show", "Copy", "Manage", "List", "Start", "Stop", "Add", "Delete"]
let services = [
    "Asana", "Trello", "GitHub", "Linear", "Notion", "Spotify", "Docker", "Figma", "Slack", "Zoom", "Dropbox", "Stripe",
    "Sentry", "Grafana", "Netlify", "Vercel", "Postman", "Discord", "YouTube Music", "Café Crème",
]
let nouns = [
    "Issues", "Tasks", "Notes", "Pages", "Files", "Projects", "Bookmarks", "Tabs", "Repos", "Branches", "Commits",
    "Deployments", "Builds", "Logs", "Secrets", "Domains", "Invoices", "Orders", "Events", "Meetings", "Playlists",
]
let appTitles = [
    "Safari", "Mail", "Calendar", "Notes", "Music", "Photos", "Messages", "Maps", "Terminal", "Preview",
    "System Settings", "Activity Monitor", "Disk Utility", "Font Book", "Keychain Access", "TextEdit", "Calculator",
]
let queries = [
    "s", "sa", "saf", "t", "te", "ter", "term", "c", "cl", "w", "vsc", "ss", "gc", "tdm", "fari", "ode", "sfari",
    "termnial", "mode dark", "vs code", "search goo", "system set", "café", "issue", "github iss", "create", "open",
    "a", "e", "dash", "spot", "musi", "zoom meet", "logs", "x", "ma",
]

/// The synthetic items of one catalog: the apps, then generated titles.
func syntheticRows(_ count: Int) -> (apps: [Row], items: [Row]) {
    var apps: [Row] = []
    var items: [Row] = []
    for i in 0..<count {
        if i < appTitles.count {
            apps.append(Row(id: ItemID("app", "com.example.\(i)"), title: appTitles[i], subtitle: "Application"))
            continue
        }
        let verb = verbs[i % verbs.count]
        let service = services[(i / verbs.count) % services.count]
        let noun = nouns[(i / (verbs.count * services.count)) % nouns.count]
        let title = i % 2 == 0 ? "\(verb) \(service) \(noun)" : "\(service): \(verb) \(noun) \(i % 97)"
        items.append(
            Row(
                id: ItemID("bench", String(i)), title: title, subtitle: service, icon: .symbol("square"),
                keywords: [noun.lowercased()]))
    }
    return (apps, items)
}

final class SyntheticSource: CatalogSource {
    let namespace: String
    let rows: [Row]
    let signal = ChangeSignal()

    var changes: ChangeSignal? { signal }

    init(namespace: String, rows: [Row]) {
        self.namespace = namespace
        self.rows = rows
    }

    func rows() async throws -> [Row] { rows }
    func actions(for row: Row) -> [Action] { [] }
}

/// An instant provider that answers only "=<number>", as a calculator would, and returns nil fast
/// for everything else, so the bench pays for the call like the app does.
final class SyntheticAnswers: InstantProvider {
    let namespace = "answer"

    func answer(for query: String) -> InstantAnswer? {
        guard query.utf8.first == UInt8(ascii: "="), let value = Int(query.dropFirst()) else { return nil }
        return InstantAnswer(
            rows: [Row(id: ItemID("answer", "x"), title: String(value), memory: .never)], claimsTop: true)
    }

    func actions(for row: Row) -> [Action] { [] }
}

/// Notes that exist only as answers, so running one exercises the remembered-row path.
final class SyntheticNotes: InstantProvider {
    let namespace = "note"

    func answer(for query: String) -> InstantAnswer? {
        guard query.hasPrefix("note ") else { return nil }
        let name = String(query.dropFirst(5))
        return InstantAnswer(rows: [Row(id: ItemID("note", name), title: "Note " + name)])
    }

    func actions(for row: Row) -> [Action] { [] }
}

/// An instant provider for unit conversions, such as "5 km", that returns nil fast for everything
/// that does not start with a digit.
final class SyntheticUnits: InstantProvider {
    let namespace = "unit"

    func answer(for query: String) -> InstantAnswer? {
        guard let first = query.utf8.first, first >= UInt8(ascii: "0"), first <= UInt8(ascii: "9"),
            query.hasSuffix(" km")
        else { return nil }
        return InstantAnswer(rows: [Row(id: ItemID("unit", "x"), title: query + " = 0.62 mi", memory: .never)])
    }

    func actions(for row: Row) -> [Action] { [] }
}

/// An async provider like a file search: 60 ms debounce, two characters at least, five rows.
final class SyntheticFiles: AsyncProvider {
    let namespace = "file"
    let sectionTitle = "Files"

    func takesOver(_ query: String) -> Bool {
        query.utf8.first == UInt8(ascii: "/")
    }

    func results(for query: String) async throws -> [Row] {
        try Task.checkCancellation()
        return (0..<8).map { Row(id: ItemID("file", "/tmp/\(query)/\($0)"), title: "\(query) file \($0)") }
    }

    func actions(for row: Row) -> [Action] { [] }
}

/// An async provider like a web search: no debounce, three characters at least, five rows.
final class SyntheticWeb: AsyncProvider {
    let namespace = "web"
    let sectionTitle = "Web"
    var debounce: Duration { .zero }
    var minimumQueryLength: Int { 3 }

    func sectionTitle(for query: String) -> String {
        "Search the web for \(query)"
    }

    func results(for query: String) async throws -> [Row] {
        (0..<5).map { Row(id: ItemID("web", "\(query)-\($0)"), title: "\(query) result \($0)") }
    }

    func actions(for row: Row) -> [Action] { [] }
}

// MARK: Measuring

struct Samples {
    let name: String
    var nanos: [UInt64] = []
    let budgetMicros: Double?

    func quantile(_ q: Double) -> Double {
        let sorted = nanos.sorted()
        return Double(sorted[Int((Double(sorted.count - 1) * q).rounded())]) / 1_000
    }

    /// Prints a table row; returns false when the p99 is over budget.
    func report() -> Bool {
        let p99 = quantile(0.99)
        let ok = budgetMicros.map { p99 <= $0 } ?? true
        let verdict = budgetMicros.map { ok ? "≤ \(Int($0)) ok" : "≤ \(Int($0)) OVER" } ?? "-"
        let cells = [quantile(0.5), p99, quantile(1)].map { String(format: "%7.1f", $0) }
        let label = name.padding(toLength: 46, withPad: " ", startingAt: 0)
        print("| \(label) | \(nanos.count) | \(cells.joined(separator: " | ")) | \(verdict) |")
        return ok
    }
}

@inline(__always) func cpu() -> UInt64 { root_bench_thread_cpu_ns() }

/// One root search over a synthetic catalog of `size` items with a learned history.
func makeRoot(size: Int) async -> (RootSearch, FakeClock, SyntheticSource) {
    let fakes = FakeServices()
    let directory = FakeFeatureDirectory()
    let preferences = FakeItemPreferences(directory: directory)
    let (apps, items) = syntheticRows(size)
    let source = SyntheticSource(namespace: "bench", rows: items)
    let context = fakes.context(featureID: "bench", environment: .bench)
    let commands = (0..<20).map { i in
        Command(
            id: "command\(i)", title: "\(verbs[i % verbs.count]) Bench \(nouns[i % nouns.count])",
            fallback: i < 2 ? Fallback { "Search Bench \(i) for \"\($0)\"" } : nil
        ) { _ in .close() }
    }
    let manifest = FeatureManifest(id: "bench", name: "Bench", icon: .symbol("gauge"))
    directory.entries = [
        FeatureEntry(
            manifest: manifest, isEnabled: true, context: context,
            commands: commands.map {
                CommandEntry(id: $0.itemID(feature: "bench"), featureID: "bench", command: $0, isEnabled: true)
            },
            catalogSources: [source],
            liveProviders: withProviders
                ? [
                    .instant(SyntheticAnswers()), .instant(SyntheticNotes()), .instant(SyntheticUnits()),
                    .async(SyntheticFiles()), .async(SyntheticWeb()),
                ]
                : [.instant(SyntheticAnswers()), .instant(SyntheticNotes())])
    ]
    preferences.setFavorites([apps[0].id, apps[1].id, apps[8].id])
    preferences.setAlias("tt", for: apps[8].id)
    let root = RootSearch(
        RootConfiguration(
            directory: directory, preferences: preferences, systemContext: FakeSystemContext(),
            settings: fakes.settings, clock: fakes.clock, storage: .inMemory, environment: .bench,
            builtInSources: [SyntheticSource(namespace: "app", rows: apps)]))
    await root.ready()

    // A learning history: 2,000 runs over 400 items, typed as 1 to 4 characters of their title.
    let all = apps + items
    for k in 0..<2_000 {
        fakes.clock.advance(by: .seconds(600))
        let target = all[(k * 7_919) % min(400, all.count)]
        let typed = String(target.title.prefix(1 + k % 4))
        _ = root.begin()
        let snapshot = root.update(query: typed)
        if let row = snapshot.rows.first(where: { $0.id == target.id }) {
            root.didRun(row, launch: .root)
        } else {
            root.didRun(target, launch: .hotkey)
        }
        root.end()
        if k % 200 == 0 { await root.settle() }
    }
    await root.settle()
    return (root, fakes.clock, source)
}

/// Every prefix of every query, built before timing so the timed calls get ready strings.
let typingScript: [[String]] = queries.map { query in
    var typed: [String] = []
    var text = ""
    for character in query {
        text.append(character)
        typed.append(text)
    }
    return typed
}

func benchUpdate(_ root: RootSearch, size: Int) -> Bool {
    var ok = true
    let timings = UpdateTimings(capacity: reps * 200)
    root.timings = timings
    var total = Samples(name: "update(query:) at \(size), all of it", budgetMicros: 500)
    var mapping = Samples(name: "update(query:) at \(size), mapping only", budgetMicros: nil)
    for _ in 0..<reps {
        for script in typingScript {
            _ = root.begin()
            for typed in script {
                let before = timings.engineNanos.count
                let start = cpu()
                let snapshot = root.update(query: typed)
                let spent = cpu() - start
                withExtendedLifetime(snapshot) {}
                total.nanos.append(spent)
                let engine = timings.engineNanos.count > before ? timings.engineNanos[before] : 0
                mapping.nanos.append(spent - min(spent, engine))
            }
            root.end()
        }
    }
    let engine = Samples(name: "update(query:) at \(size), engine only", nanos: timings.engineNanos, budgetMicros: nil)
    root.timings = nil
    ok = total.report() && ok
    _ = engine.report()
    _ = mapping.report()
    return ok
}

/// The keystroke as the main thread pays for it with async providers: update(query:), then the turns
/// of the main actor in which the providers' tasks start their debounce, as they would before the
/// next keystroke. Then the cost of putting one async section into the snapshot, measured inside
/// root search after the debounce passed.
func benchAsync(_ root: RootSearch, clock: FakeClock, size: Int) async {
    var keystroke = Samples(name: "update(query:) at \(size) + async task start", budgetMicros: nil)
    for _ in 0..<max(1, reps / 3) {
        for script in typingScript {
            _ = root.begin()
            for typed in script {
                let start = cpu()
                let snapshot = root.update(query: typed)
                for _ in 0..<4 { await Task.yield() }
                keystroke.nanos.append(cpu() - start)
                withExtendedLifetime(snapshot) {}
            }
            root.end()
        }
    }
    _ = keystroke.report()

    let timings = UpdateTimings(capacity: reps * 100)
    root.timings = timings
    for _ in 0..<max(1, reps / 3) {
        for script in typingScript {
            guard let typed = script.last, typed.count >= 2 else { continue }
            _ = root.begin()
            _ = root.update(query: typed)
            for _ in 0..<8 { await Task.yield() }
            clock.advance(by: .milliseconds(60))
            await root.providersFinished()
            root.end()
        }
    }
    root.timings = nil
    _ = Samples(name: "async section into the snapshot at \(size)", nanos: timings.deliveryNanos, budgetMicros: nil)
        .report()
}

func benchBegin(_ root: RootSearch, size: Int) -> Bool {
    var begin = Samples(name: "begin() at \(size)", budgetMicros: 100)
    for k in 0..<(reps * 60) {
        let start = cpu()
        let snapshot = root.begin()
        begin.nanos.append(cpu() - start)
        withExtendedLifetime(snapshot) {}
        _ = root.update(query: typingScript[k % typingScript.count].last ?? "a")
        root.end()
    }
    return begin.report()
}

func benchDidRun(_ root: RootSearch, clock: FakeClock, size: Int) async -> Bool {
    var catalogRuns = Samples(name: "didRun at \(size), catalog row", budgetMicros: 200)
    var rememberedRuns = Samples(name: "didRun at \(size), new remembered row", budgetMicros: 200)
    for k in 0..<(reps * 20) {
        clock.advance(by: .seconds(30))
        let remembered = k % 2 == 1
        _ = root.begin()
        let typed = remembered ? "note n\(k)" : (typingScript[k % typingScript.count].last ?? "a")
        let snapshot = root.update(query: typed)
        let row = remembered ? snapshot.rows.first { $0.id.namespace == "note" } : snapshot.rows.first
        guard let row else {
            root.end()
            continue
        }
        let start = cpu()
        root.didRun(row, launch: .root)
        let spent = cpu() - start
        root.end()
        if remembered { rememberedRuns.nanos.append(spent) } else { catalogRuns.nanos.append(spent) }
        // Let the engine queue keep up, as it does between real runs.
        if k % 10 == 9 { await root.settle() }
    }
    await root.settle()
    let ok = catalogRuns.report()
    return rememberedRuns.report() && ok
}

/// Heap allocations per keystroke: inside the engine call, which must be none, and in all of
/// update(query:), which is the mapping's count since the engine adds none.
func benchAllocations(_ root: RootSearch, size: Int) -> Bool {
    guard let engine = root.benchEngine, let buffer = try? QueryBuffer(capacity: 50) else { return false }
    var keystrokes = 0
    for script in typingScript {
        for typed in script { _ = try? engine.query(typed, into: buffer) }
    }
    root_bench_alloc_begin()
    for script in typingScript {
        buffer.reset()
        for typed in script {
            _ = try? engine.query(typed, into: buffer)
            keystrokes += 1
        }
    }
    let engineAllocations = root_bench_alloc_end()

    for script in typingScript {
        _ = root.begin()
        for typed in script { _ = root.update(query: typed) }
        root.end()
    }
    var perQuery: [UInt64] = []
    perQuery.reserveCapacity(keystrokes)
    for script in typingScript {
        _ = root.begin()
        for typed in script {
            root_bench_alloc_begin()
            let snapshot = root.update(query: typed)
            let count = root_bench_alloc_end()
            withExtendedLifetime(snapshot) {}
            perQuery.append(count)
        }
        root.end()
    }
    perQuery.sort()
    let mean = Double(perQuery.reduce(0, +)) / Double(max(perQuery.count, 1))
    print(
        "allocations at \(size): engine call \(engineAllocations) over \(keystrokes) keystrokes; "
            + "update(query:) mean \(String(format: "%.1f", mean)), p50 \(perQuery[perQuery.count / 2]), "
            + "max \(perQuery.last ?? 0) per keystroke")
    return engineAllocations == 0
}

func benchRebuild(_ root: RootSearch, source: SyntheticSource, size: Int) async {
    var walls: [Double] = []
    for _ in 0..<5 {
        let start = DispatchTime.now().uptimeNanoseconds
        source.signal.send()
        await root.settle()
        walls.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
    walls.sort()
    print(
        "catalog reload and rebuild at \(size), off the main thread, wall ms: p50 \(String(format: "%.2f", walls[2])), max \(String(format: "%.2f", walls[4]))"
    )
}

// MARK: Main

var ok = true
print(
    "Root bench: release build, main-thread CPU time, QoS \(qos) (main thread reports \(qos_class_self().rawValue)), reps \(reps)"
)
print(
    withProviders
        ? "Providers: 3 instant, 2 async (60 ms and no debounce)\n" : "Providers: 2 instant, no async\n")
for size in [3_000, 10_000] {
    let (root, clock, source) = await makeRoot(size: size)
    print("catalog at \(size): \(root.catalogCount) items in the table\n")
    print("| case | n | p50 µs | p99 µs | max µs | budget p99 |")
    print("|---|---|---|---|---|---|")
    ok = benchUpdate(root, size: size) && ok
    if withProviders { await benchAsync(root, clock: clock, size: size) }
    ok = benchBegin(root, size: size) && ok
    ok = await benchDidRun(root, clock: clock, size: size) && ok
    print("")
    ok = benchAllocations(root, size: size) && ok
    await benchRebuild(root, source: source, size: size)
    print("")
    await root.shutdown()
}
if !ok {
    FileHandle.standardError.write(Data("a latency or allocation budget was blown\n".utf8))
    exit(1)
}
