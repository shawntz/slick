import AppKit
import Darwin
import Foundation
import Testing

@testable import Define

/// The live service against this Mac's own dictionaries and spell checker. Both read only what
/// ships with macOS, never prompt and use no network, so this is the one place a test calls them.
/// Opt in with `DEFINE_LIVE_TEST=1`:
///
///     DEFINE_LIVE_TEST=1 scripts/swiftpm.sh Packages/Features/Define test --filter Live
///
/// It prints wall time per lookup with n, p50, p99 and the load average, and the main thread's CPU
/// time while the lookups ran. `DEFINE_LIVE_SHAPES=1` also prints how the parser
/// split each entry, to compare with the system's text by eye. Nothing it prints is kept.
@Suite(
    "Live", .serialized, .enabled(if: ProcessInfo.processInfo.environment["DEFINE_LIVE_TEST"] == "1"),
    .timeLimit(.minutes(2)))
struct LiveLookupTests {
    /// Ten of the most common English words.
    static let words = ["time", "person", "year", "way", "day", "thing", "man", "world", "life", "hand"]
    static let rounds = 5

    @Test func lookupsAreTimedAndLeaveTheMainActorFree() async throws {
        #expect(pthread_main_np() != 0)
        let lookup = Lookup(service: SystemLookup())
        // The first spelling call makes the shared spell checker on the main actor, once per
        // launch. Measured on its own, since it is the only main-actor work a lookup does.
        let creation = Self.measure { _ = NSSpellChecker.shared }
        let firstSpelling = try await Self.timed { _ = try await lookup.spelling(of: LookupTerm.make("time")!) }

        // This test runs on the main thread, so its CPU time counts what the main thread did
        // while the lookups ran: starting them and taking their answers, nothing more.
        let mainBefore = Self.threadNanoseconds()
        var definitionTimes: [Double] = []
        var spellingTimes: [Double] = []
        for _ in 0..<Self.rounds {
            for word in Self.words {
                let term = try #require(LookupTerm.make(word))
                var definition: Definition?
                definitionTimes.append(try await Self.timed { definition = try await lookup.definition(of: term) })
                let found = try #require(definition, "no entry for \(word)")
                #expect(found.isStructured, "\(word) did not parse")
                #expect(!found.summary.isEmpty, "\(word) has no summary")
                spellingTimes.append(try await Self.timed { _ = try await lookup.spelling(of: term) })
            }
        }
        let mainCPU = Double(Self.threadNanoseconds() - mainBefore) / 1e6
        let wall = (definitionTimes + spellingTimes).reduce(0, +)
        Self.report("definition, parsed", definitionTimes)
        Self.report("spelling, verdict and guesses", spellingTimes)
        print("LIVE making the shared spell checker on the main actor, once: \(String(format: "%.2f", creation)) ms")
        print("LIVE first spelling call after that: \(String(format: "%.2f", firstSpelling)) ms")
        print(
            String(
                format: "LIVE main-thread CPU while 100 lookups ran: %.2f ms in all, against %.0f ms of lookups",
                mainCPU,
                wall))
        #expect(mainCPU < wall / 10)
    }

    @Test func spellingFindsMistakesAndTheirLanguage() async throws {
        let lookup = Lookup(service: SystemLookup())
        let misspelled = try await lookup.spelling(of: LookupTerm.make("recieve")!)
        #expect(misspelled.verdict == .misspelled)
        #expect(misspelled.guesses.contains("receive"))
        let correct = try await lookup.spelling(of: LookupTerm.make("lantern")!)
        #expect(correct.verdict == .correct)
        let nothing = try await lookup.definition(of: LookupTerm.make("xqzzvwq")!)
        #expect(nothing == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DEFINE_LIVE_SHAPES"] == "1"))
    func printsHowEntriesSplit() async throws {
        let words =
            ProcessInfo.processInfo.environment["DEFINE_WORDS"]?.split(separator: ",").map(String.init) ?? Self.words
        let lookup = Lookup(service: SystemLookup())
        for word in words {
            guard let term = LookupTerm.make(word), let definition = try await lookup.definition(of: term) else {
                print("SHAPE \(word): no entry")
                continue
            }
            print(
                "SHAPE \(word) -> headword=\(definition.headword) syllables=\(definition.syllables ?? "-") pronunciation=\(definition.pronunciation ?? "-") structured=\(definition.isStructured)"
            )
            print("SHAPE   summary: \(definition.summary)")
            for paragraph in definition.paragraphs {
                print("SHAPE   \(String(describing: paragraph).prefix(110))")
            }
        }
    }

    // MARK: Measuring

    nonisolated private static func threadNanoseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    }

    private static func measure(_ work: () -> Void) -> Double {
        let start = ContinuousClock.now
        work()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
    }

    private static func timed(_ work: () async throws -> Void) async rethrows -> Double {
        let start = ContinuousClock.now
        try await work()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
    }

    private static func report(_ name: String, _ values: [Double]) {
        var load = [0.0, 0.0, 0.0]
        getloadavg(&load, 3)
        print(
            String(
                format: "LIVE %@: n=%d p50 %.2f ms p99 %.2f ms max %.2f ms load %.1f", name, values.count,
                percentile(values, 0.5), percentile(values, 0.99), values.max() ?? 0, load[0]))
    }
}
