import Darwin
import Foundation
import Kit
import KitTesting
import Testing

@testable import Define

/// Measures the work this feature does on the main actor inside an interaction, and the parser,
/// which runs off it. Opt in with `DEFINE_BENCHMARK=1`, in a release build:
///
///     DEFINE_BENCHMARK=1 scripts/swiftpm.sh Packages/Features/Define test -c release \
///         -Xswiftc -enable-testing --filter Benchmark
///
/// Each line prints n, p50, p99 and max in microseconds of thread CPU time, and the load average.
/// Settings come from the in-memory fake, not from the app's settings store.
@Suite(
    "Benchmark", .serialized, .enabled(if: ProcessInfo.processInfo.environment["DEFINE_BENCHMARK"] == "1"),
    .timeLimit(.minutes(5)))
struct Benchmark {
    /// Inside every keystroke: whether the provider claims the query, its title and its debounce.
    /// Budget: as cheap as an instant provider, 100 µs.
    @Test func rootSearchKeystrokes() {
        let harness = makeHarness()
        let provider = harness.feature.provider
        let typed = ["define lantern", "spell recieve", "define ice cream", "dictionary", "safari", "spellbook"]
        var keyword: [Double] = []
        for round in 0..<200 {
            for text in typed {
                var query = ""
                for character in text {
                    query.append(character)
                    let start = Self.threadNanoseconds()
                    let claimed = provider.takesOver(query)
                    let title = provider.sectionTitle(for: query)
                    let wait = provider.debounce(for: query)
                    let used = Self.threadNanoseconds() - start
                    if round > 0 { keyword.append(Double(used) / 1_000) }
                    withExtendedLifetime((claimed, title, wait)) {}
                }
            }
        }
        Self.report("takesOver, sectionTitle and debounce per keystroke", keyword)
        var foreign: [Double] = []
        let pasted = String(repeating: "word ", count: 200_000)
        for _ in 0..<2_000 {
            for query in ["safari", "~/Documents", pasted] {
                let start = Self.threadNanoseconds()
                _ = provider.takesOver(query)
                foreign.append(Double(Self.threadNanoseconds() - start) / 1_000)
            }
        }
        Self.report("takesOver, foreign and pasted queries", foreign)
        #expect(Self.percentile(keyword, 0.99) < 100)
        #expect(Self.percentile(foreign, 0.99) < 100)
    }

    /// When the selection settles or the action panel opens.
    @Test func actionsForARow() async throws {
        let harness = makeHarness()
        let definition = try #require(DefinitionParser.parse(FixtureLookup.harbor, term: "harbor") as Definition?)
        let rows =
            [WordRows.definition(definition)] + WordRows.suggestions(["receive", "relieve"])
            + WordRows.spelling(LookupTerm.make("recieve")!, Spelling(.misspelled, guesses: ["receive"])).flatMap(
                \.rows)
        var times: [Double] = []
        for _ in 0..<2_000 {
            for row in rows {
                let start = Self.threadNanoseconds()
                let actions = harness.feature.pages.actions(for: row)
                times.append(Double(Self.threadNanoseconds() - start) / 1_000)
                withExtendedLifetime(actions) {}
            }
        }
        Self.report("actions(for:)", times)
    }

    /// When the selection hotkey offers actions for selected text.
    @Test func universalActions() {
        let harness = makeHarness()
        let provider = harness.feature.universalActions[0]
        let selections: [Selection] = [
            .text("lantern"), .text("ice cream"), .text(String(repeating: "text ", count: 2_000_000)),
        ]
        var times: [Double] = []
        for _ in 0..<500 {
            for selection in selections {
                let start = Self.threadNanoseconds()
                let actions = provider.actions(selection)
                times.append(Double(Self.threadNanoseconds() - start) / 1_000)
                withExtendedLifetime(actions) {}
            }
        }
        Self.report("universal actions, including a 10 MB selection", times)
        #expect(Self.percentile(times, 0.99) < 1_000)
    }

    /// Off the main actor, after each lookup: parsing an entry as long as the longest English
    /// ones, about 20,000 characters.
    @Test func parsingALongEntry() {
        var senses = ""
        for number in 1...60 {
            senses +=
                "\(number) [with object] a sense with some words in it: an example of the sense in use | another one. • a subsense with more words in it: an example. • another subsense here. "
        }
        let raw = "walk | wôk | verb (walks) (, walking | ˈwôkiNG |) " + senses + "ORIGIN Old English."
        var times: [Double] = []
        var paragraphs = 0
        for round in 0..<101 {
            let start = Self.threadNanoseconds()
            let definition = DefinitionParser.parse(raw, term: "walk")
            if round > 0 { times.append(Double(Self.threadNanoseconds() - start) / 1_000) }
            paragraphs = definition.paragraphs.count
        }
        Self.report("parse \(raw.count) characters into \(paragraphs) paragraphs", times)
    }

    // MARK: Measuring

    nonisolated private static func threadNanoseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    }

    nonisolated private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
    }

    private static func report(_ name: String, _ values: [Double]) {
        var load = [0.0, 0.0, 0.0]
        getloadavg(&load, 3)
        print(
            String(
                format: "BENCH %@: n=%d p50 %.2f µs p99 %.2f µs max %.2f µs load %.1f", name, values.count,
                percentile(values, 0.5), percentile(values, 0.99), values.max() ?? 0, load[0]))
    }
}
