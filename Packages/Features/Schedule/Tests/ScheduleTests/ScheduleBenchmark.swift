import Foundation
import Kit
import KitTesting
import Testing

@testable import Schedule

/// Times what runs while the user waits: building My Schedule's rows for a busy month, the action
/// panel's actions on the main thread, the link finder on a long invitation and the suggestion.
/// Opt in with `SCHEDULE_BENCHMARK=1`, in a release build:
///
///     SCHEDULE_BENCHMARK=1 scripts/swiftpm.sh Packages/Features/Schedule test -c release \
///         -Xswiftc -enable-testing --filter ScheduleBenchmark
///
/// Events are synthetic. It prints counts and times only.
@Suite(
    "Benchmark: a busy month", .serialized, .timeLimit(.minutes(10)),
    .enabled(if: ProcessInfo.processInfo.environment["SCHEDULE_BENCHMARK"] == "1"))
@MainActor
struct ScheduleBenchmark {
    typealias F = Fixture

    /// 2,000 events over 31 days, a third with a Teams invitation in the notes, some all-day and
    /// some over several days.
    static func month() -> [EventOccurrence] {
        (0..<2_000).map { index in
            let start = F.start.addingTimeInterval(TimeInterval(index) * 31 * 86_400 / 2_000)
            let notes = index % 3 == 0 ? MeetingLinkFinderTests.teamsInvitation : "Agenda item \(index)"
            return F.event(
                "e\(index)", "Event \(index)", start: start, minutes: 30 + index % 90,
                calendar: index % 2 == 0 ? F.work : F.home, allDay: index % 50 == 0, location: "Room \(index % 12)",
                notes: notes, recurring: index % 7 == 0,
                end: index % 97 == 0 ? start.addingTimeInterval(3 * 86_400) : nil)
        }
    }

    @Test func buildingRows() async throws {
        let events = Self.month()
        let clock = FrozenClock(F.clock(F.start))
        var rows = 0
        let samples = await Self.samples(40) {
            // What a load builds: the sections and when they go stale.
            let page = await EventRows.page(events, options: ScheduleOptions(days: 31), clock: clock)
            rows = page.sections.reduce(0) { $0 + $1.rows.count }
        }
        Self.report("My Schedule rows and refresh delay, 2,000 events, off main, wall", samples, extra: "rows=\(rows)")
    }

    @Test func actionPanel() async throws {
        let store = F.store(events: Array(Self.month().prefix(300)))
        let harness = F.harness(store)
        try await harness.run("my-schedule")
        guard case .list(let page) = harness.page?.page else { return }
        let rows = harness.rows
        var samples: [Double] = []
        for index in 0..<4_000 {
            let row = rows[index % rows.count]
            let start = ContinuousClock.now
            _ = page.source.actions(for: row)
            samples.append(Self.microseconds(ContinuousClock.now - start))
        }
        Self.report("actions(for:), main thread", samples, unit: "us")
    }

    @Test func linkFinder() {
        let long = String(repeating: MeetingLinkFinderTests.teamsInvitation, count: 20)
        var samples: [Double] = []
        for _ in 0..<500 {
            let start = ContinuousClock.now
            _ = MeetingLinkFinder.find(url: nil, location: "Room 4", notes: long)
            samples.append(Self.microseconds(ContinuousClock.now - start))
        }
        Self.report("link finder, \(long.utf8.count) bytes of notes", samples, unit: "us")
    }

    @Test func suggestion() async throws {
        let harness = F.harness(F.store(events: Self.month()))
        var samples: [Double] = []
        for minute in 0..<200 {
            let date = F.start.addingTimeInterval(TimeInterval(minute * 300))
            let start = ContinuousClock.now
            _ = try await harness.suggestions(at: date)
            samples.append(Self.microseconds(ContinuousClock.now - start))
        }
        Self.report("suggestions(at:), wall", samples, unit: "us")
    }

    // MARK: - Measuring

    static func samples(_ count: Int, _ work: () async -> Void) async -> [Double] {
        var samples: [Double] = []
        for _ in 0..<count {
            let start = ContinuousClock.now
            await work()
            samples.append(microseconds(ContinuousClock.now - start) / 1_000)
        }
        return samples
    }

    static func microseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1e6 + Double(duration.components.attoseconds) * 1e-12
    }

    static func report(_ name: String, _ samples: [Double], unit: String = "ms", extra: String = "") {
        let sorted = samples.sorted()
        func percentile(_ fraction: Double) -> Double {
            sorted[min(sorted.count - 1, Int((Double(sorted.count) * fraction).rounded(.down)))]
        }
        let line = String(
            format: "BENCH %@: n=%d p50=%.2f%@ p99=%.2f%@ max=%.2f%@ %@", name, sorted.count, percentile(0.5), unit,
            percentile(0.99), unit, sorted.last ?? 0, unit, extra)
        print(line)
    }
}
