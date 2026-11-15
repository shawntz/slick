import Darwin
import Foundation
import Kit
import KitTesting
import Testing

@testable import Quicklinks

/// The instant provider's budget: 100 microseconds per keystroke on the main thread. Opt in with
/// `QUICKLINKS_BENCHMARK=1`, and run in release with `-Xswiftc -enable-testing`. Prints counts,
/// times and the load average only.
@Suite(
    "Address detector budget", .serialized, .timeLimit(.minutes(2)),
    .enabled(if: ProcessInfo.processInfo.environment["QUICKLINKS_BENCHMARK"] == "1"))
@MainActor
struct AddressBenchmark {
    /// What people type into root search, as it grows key by key.
    static let words = [
        "s", "sa", "saf", "safa", "safari", "calendar", "system settings", "clipboard history", "quit all", "emoji",
        "README.md", "setup.py", "1.5", "10:30", "v1.2.3", "node.js", "/usr/local/lib", ":smile", "~/notes",
        "=12*3",
    ]
    static let addresses = [
        "example.com", "docs.example.com/guide?x=1#top", "localhost:3000", "https://example.org/a/b/c",
        "192.168.1.20:8080/status", "www.notes.md",
    ]

    @Test func theInstantAnswerStaysInsideItsBudget() async throws {
        let quicklinks = try await QuicklinksHarness()
        guard case .instant(let provider) = try #require(quicklinks.feature.liveProviders.first) else {
            Issue.record("expected an instant provider")
            return
        }
        let load = loadAverage()
        let rounds = 2000
        for _ in 0..<200 {
            for query in Self.words + Self.addresses { _ = provider.answer(for: query) }
        }
        var wordTimes: [Duration] = []
        var addressTimes: [Duration] = []
        let clock = ContinuousClock()
        for _ in 0..<rounds {
            for query in Self.words {
                let start = clock.now
                let answer = provider.answer(for: query)
                wordTimes.append(clock.now - start)
                #expect(answer == nil)
            }
            for query in Self.addresses {
                let start = clock.now
                let answer = provider.answer(for: query)
                addressTimes.append(clock.now - start)
                #expect(answer != nil)
            }
        }
        let words = Summary(wordTimes)
        let addresses = Summary(addressTimes)
        print("quicklinks-benchmark load-before=\(load) load-after=\(loadAverage())")
        print("quicklinks-benchmark words \(words)")
        print("quicklinks-benchmark addresses \(addresses)")
        #expect(words.p99 < .microseconds(100))
        #expect(addresses.p99 < .microseconds(100))
    }

    /// What the main thread still does with fifty thousand quicklinks: read the declarations, the
    /// settings pane, the default engine and a row's actions. Parsing runs off it.
    @Test func declarationsAtFiftyThousand() async throws {
        let quicklinks = try await QuicklinksHarness(file: ScaleTests.bigFile(50_000))
        let feature = quicklinks.feature
        let load = loadAverage()
        let clock = ContinuousClock()
        var commands: [Duration] = []
        var panes: [Duration] = []
        var engines: [Duration] = []
        var actions: [Duration] = []
        let row = QuicklinkRows.catalogRow(try #require(feature.entries.first))
        let catalog = try #require(feature.catalogSources.first)
        for _ in 0..<20 {
            commands.append(clock.measure { _ = feature.commands })
            panes.append(clock.measure { _ = feature.settingsPane })
        }
        for _ in 0..<2000 {
            engines.append(clock.measure { _ = feature.defaultEngine })
            actions.append(clock.measure { _ = catalog.actions(for: row) })
        }
        print("quicklinks-benchmark load=\(load)")
        print("quicklinks-benchmark commands-50k \(Summary(commands))")
        print("quicklinks-benchmark pane-50k \(Summary(panes))")
        print("quicklinks-benchmark default-engine-50k \(Summary(engines))")
        print("quicklinks-benchmark row-actions-50k \(Summary(actions))")
    }

    private func loadAverage() -> String {
        var values = [Double](repeating: 0, count: 3)
        guard getloadavg(&values, 3) == 3 else { return "unknown" }
        return values.map { String(format: "%.2f", $0) }.joined(separator: "/")
    }
}

/// Percentiles of a set of times.
struct Summary: CustomStringConvertible {
    let count: Int
    let p50: Duration
    let p99: Duration
    let maximum: Duration

    init(_ times: [Duration]) {
        let sorted = times.sorted()
        count = sorted.count
        p50 = sorted[sorted.count / 2]
        p99 = sorted[min(sorted.count - 1, sorted.count * 99 / 100)]
        maximum = sorted[sorted.count - 1]
    }

    var description: String {
        "n=\(count) p50=\(Self.micro(p50)) p99=\(Self.micro(p99)) max=\(Self.micro(maximum))"
    }

    private static func micro(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        let micro = Double(seconds) * 1_000_000 + Double(attoseconds) / 1_000_000_000_000
        return String(format: "%.2fus", micro)
    }
}
