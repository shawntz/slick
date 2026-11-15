import Foundation
import Kit
import KitTesting
import Synchronization
import Testing

@testable import MenuItems

/// The budget: with 5,000 items in the isolated reader, the first page shows in under 50 ms and
/// filtering stays off the main thread.
///
/// The first test runs every time with a loose bound, so a slip shows without making the suite
/// flaky on a busy machine. The benchmark runs only with `MENUITEMS_BENCHMARK=1` and prints p50
/// and p99.
@MainActor
@Suite("Budget", .serialized, .timeLimit(.minutes(5)))
struct BudgetTests {
    static let large = Trees.large(5_000)

    /// Runs the command and returns once the first page of rows shows.
    static func openFirstPage(_ menu: MenuHarness) async throws -> Duration {
        let clock = ContinuousClock()
        let start = clock.now
        try await menu.harness.run("search")
        if menu.harness.rows.isEmpty {
            await menu.list?.readFinished()
            try await menu.harness.settle()
        }
        return clock.now - start
    }

    @Test func fiveThousandItemsShowTheirFirstPageAndSearchOffTheMainThread() async throws {
        let menu = MenuHarness(menuBar: Self.large)
        let took = try await Self.openFirstPage(menu)
        let harness = menu.harness
        #expect(harness.rows.count == MenuRows.pageSize)
        #expect(harness.page?.nextPage != nil)
        #expect(took < .milliseconds(500), "a loose bound; the benchmark checks 50 ms")
        let read = try #require(harness.feature.cache.entry(for: "com.example.editor")?.snapshot)
        #expect(read.items.filter { !$0.isInAppleMenu }.count == 5_000)

        try await harness.setQuery("command 7.3.1")
        #expect(harness.rows.first?.title == "Command 7.3.1")
        #expect(harness.rows.first?.subtitle == "Menu 7 › Group 7.3")
        #expect(harness.rows.first?.accessories == [.shortcut(KeyCombo(.j, [.shift, .command]))])
        try await harness.setQuery("9.20.25")
        #expect(harness.rows.first?.title == "Command 9.20.25")
        #expect(MenuRows.searchesOnMainThread.load(ordering: .relaxed) == 0)
        #expect(harness.issues.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MENUITEMS_BENCHMARK"] == "1"))
    func benchmark() async throws {
        let rounds = 100
        var cold: [Duration] = []
        var warm: [Duration] = []
        var searches: [Duration] = []
        for _ in 0..<rounds {
            let menu = MenuHarness(menuBar: Self.large)
            cold.append(try await Self.openFirstPage(menu))
            try await menu.settled()
            menu.harness.pop()
            warm.append(try await Self.openFirstPage(menu))
            #expect(menu.harness.rows.count == MenuRows.pageSize)
            try await menu.settled()
            for query in ["command", "group 4", "command 3.12.7", "zz"] {
                let clock = ContinuousClock()
                let start = clock.now
                try await menu.harness.setQuery(query)
                searches.append(clock.now - start)
            }
        }
        let load = Self.loadAverage()
        print("menu-items benchmark, 5,000 items, load \(load)")
        print("  first page, cold: \(Self.summary(cold))")
        print("  first page, cached: \(Self.summary(warm))")
        print("  search, typed query to rows: \(Self.summary(searches))")
        #expect(Self.percentile(cold, 0.99) < .milliseconds(50))
        #expect(Self.percentile(warm, 0.99) < .milliseconds(50))
    }

    static func percentile(_ samples: [Duration], _ fraction: Double) -> Duration {
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count) * fraction).rounded(.up)) - 1)
        return sorted[max(0, index)]
    }

    static func summary(_ samples: [Duration]) -> String {
        func ms(_ duration: Duration) -> String {
            let value = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
            return String(format: "%.2f ms", value)
        }
        return "n=\(samples.count) p50 \(ms(percentile(samples, 0.5))) p99 \(ms(percentile(samples, 0.99)))"
    }

    static func loadAverage() -> String {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return "unknown" }
        return String(format: "%.1f %.1f %.1f", loads[0], loads[1], loads[2])
    }
}
