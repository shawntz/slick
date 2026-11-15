// The file index through CoreBridge: searches over synthetic indexes of 100,000 and 1,000,000
// entries, cold and typed char by char, from a thread at the user-initiated QoS class, where the
// app's search queue runs. The parallel rows are the app's path and carry the budgets: 1 ms p99 at
// 100,000 entries and 5 ms p99 at 1,000,000. The one-thread rows are references; slick-files states
// 1 ms p99 at 100,000 entries on one thread, which the typed row is known to miss.
import BenchSupport
import CoreBridge
import Foundation

let fileQueries = [
    "a", "s", "e", "r", "re", "sc", "in", "ma", "co", "rea", "scr", "inv", "conf", "read", "main", "repo", "readme",
    "screenshot", "invoice", "budget 2024", "docs readme", "report pdf", ".pdf", "src/main", "raedme", "scrennshot",
    "zzqx", "meeting notes", "photo jpg", "project src", "index.js", "test", "IMG", "final draft", "x", "café",
]

/// Cold and typed searches over `index`. Returns false when a budget is blown.
func measureFileSearch(
    _ index: FileIndex, label: String, parallel: Bool, reps: Int, budget: Double?, sink: inout Int
) throws -> Bool {
    let session = try FileSearchSession(capacity: 50)
    let options = FileSearchOptions(now: 1_794_000_000, parallel: parallel)
    for q in fileQueries {
        session.reset()
        try session.search(q, in: index, options: options)
    }
    var cold = Samples(name: "files \(label), cold", budget: budget)
    var typed = Samples(name: "files \(label), typed char by char", budget: budget)
    var slowest: [(Double, String)] = []
    for _ in 0..<reps {
        for q in fileQueries {
            session.reset()
            sink &+= try cold.time { try session.search(q, in: index, options: options) }
            slowest.append((cold.micros.last ?? 0, q))
        }
        for q in fileQueries {
            session.reset()
            var text = ""
            for c in q {
                text.append(c)
                sink &+= try typed.time { try session.search(text, in: index, options: options) }
            }
        }
    }
    let coldOK = cold.report()
    let typedOK = typed.report()
    var seen: [String] = []
    for (t, q) in slowest.sorted(by: { $0.0 > $1.0 }) where !seen.contains(q) && seen.count < 5 {
        seen.append(q)
        print("    slow: \(q) \(Int(t)) µs")
    }
    return coldOK && typedOK
}

/// Returns false when a budget is blown.
func measureFiles(sink: inout Int) throws -> Bool {
    if ProcessInfo.processInfo.environment["BENCH_QOS"] != "background" {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)
    }
    var ok = true
    var started = bench_now_ns()
    let hundred = try FileIndex.synthetic(root: "/synthetic/hundred-k", entries: 100_000, seed: 1)
    print("files: 100,000 synthetic entries built in \((bench_now_ns() - started) / 1_000_000) ms")
    _ = try measureFileSearch(
        hundred, label: "100k, one thread, reference", parallel: false, reps: reps / 3, budget: nil, sink: &sink)
    ok =
        try measureFileSearch(
            hundred, label: "100k, parallel", parallel: true, reps: reps / 3, budget: 1_000, sink: &sink) && ok
    started = bench_now_ns()
    let million = try FileIndex.synthetic(root: "/synthetic/million", entries: 1_000_000, seed: 2)
    print("files: 1,000,000 synthetic entries built in \((bench_now_ns() - started) / 1_000_000) ms")
    ok =
        try measureFileSearch(
            million, label: "1M, parallel", parallel: true, reps: max(1, reps / 6), budget: 5_000, sink: &sink) && ok
    _ = try measureFileSearch(
        million, label: "1M, one thread, reference", parallel: false, reps: 1, budget: nil, sink: &sink)
    return ok
}
