import Foundation
import Kit
import KitTesting
import Testing

@testable import MarkdownNotes

/// Timings for the paths that run inside a keystroke or a page load. Opt in with
/// `NOTES_BENCHMARK=1`, in a release build with `-enable-testing`. They print numbers and assert
/// nothing, so a busy machine cannot fail them.
@Suite(
    "Benchmark", .timeLimit(.minutes(2)),
    .enabled(if: ProcessInfo.processInfo.environment["NOTES_BENCHMARK"] == "1"))
struct Benchmark {
    static func percentiles(_ samples: [Duration]) -> String {
        let sorted = samples.sorted()
        func micros(_ value: Duration) -> String {
            let seconds = Double(value.components.seconds) + Double(value.components.attoseconds) * 1e-18
            return String(format: "%.2f", seconds * 1e6)
        }
        let p50 = sorted[sorted.count / 2]
        let p99 = sorted[min(sorted.count - 1, sorted.count * 99 / 100)]
        return "n \(sorted.count), p50 \(micros(p50)) µs, p99 \(micros(p99)) µs, max \(micros(sorted.last ?? .zero)) µs"
    }

    @Test func quickCaptureOnEveryKeystroke() async throws {
        let harness = try await FeatureHarness.make()
        let provider = try #require(harness.feature.liveProviders.first)
        guard case .instant(let capture) = provider else { return }
        let typed = "note buy oat milk and bread for the weekend"
        let pasted = "note " + String(repeating: "a long pasted paragraph ", count: 20_000)
        let foreign = ["safari", "calendar", "2 + 2", "日本語のテキスト", String(repeating: "x", count: 100_000)]
        var answers: [Duration] = []
        var refusals: [Duration] = []
        let clock = ContinuousClock()
        for _ in 0..<200 {
            for end in typed.indices.dropFirst() {
                let query = String(typed[..<end])
                answers.append(clock.measure { _ = capture.answer(for: query) })
            }
            answers.append(clock.measure { _ = capture.answer(for: pasted) })
            for query in foreign {
                refusals.append(clock.measure { _ = capture.answer(for: query) })
            }
        }
        print("Notes benchmark, quick capture answers: \(Self.percentiles(answers))")
        print("Notes benchmark, quick capture refusals: \(Self.percentiles(refusals))")
    }

    @Test func searchAndScanOverFiveThousandNotes() async throws {
        let harness = try await FeatureHarness.make()
        let words = ["budget", "trip", "garden", "recipe", "meeting", "draft", "ideas", "plans", "books", "music"]
        for number in 0..<5_000 {
            let topic = words[number % words.count]
            let body = (0..<40).map { words[($0 * 7 + number) % words.count] }.joined(separator: " ")
            try harness.write(
                "Note \(number).md", "# \(topic.capitalized) \(number)\n\n\(body) café \(number)\n",
                modified: daysAgo(Double(number % 60), hours: Double(number % 24), clock: harness.fakes.clock))
        }
        let clock = ContinuousClock()
        let scan = await clock.measure { await harness.library.rescan() }
        let rescan = await clock.measure { await harness.library.rescan() }
        print("Notes benchmark, first scan of 5,000 notes: \(scan), rescan with nothing changed: \(rescan)")

        let index = harness.library.index
        let days = DaySections(clock: harness.fakes.clock, direction: .past)
        var searches: [Duration] = []
        for query in ["b", "bu", "bud", "budget", "budget trip", "cafe 4321", "zebra", ""] {
            for _ in 0..<20 {
                let parsed = NoteQuery(query)
                searches.append(
                    try await clock.measure {
                        _ = try await NoteRows.sections(index, pinned: [], query: parsed, days: days)
                    })
            }
        }
        print("Notes benchmark, Search Notes sections over 5,000 notes: \(Self.percentiles(searches))")

        try await harness.openSearch()
        try harness.select(at: 0)
        var actions: [Duration] = []
        for _ in 0..<500 {
            let row = try #require(harness.selectedRow)
            actions.append(clock.measure { _ = harness.feature.catalogSources[0].actions(for: row) })
        }
        print("Notes benchmark, actions(for:) on the main thread: \(Self.percentiles(actions))")
    }
}
