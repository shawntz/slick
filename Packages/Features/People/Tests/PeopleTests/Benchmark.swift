import Foundation
import Kit
import KitTesting
import Testing

@testable import People

/// Ten thousand invented people: names from short fixed lists, every tenth in Cyrillic and every
/// twentieth in Han, every seventh a company card, numbers in the 555-01xx range and addresses
/// under example.com.
nonisolated func inventedPeople(_ count: Int) -> [Person] {
    let given = ["Ana", "Bruno", "Chloé", "Dmitri", "Elif", "Farah", "Goran", "Hana", "Ines", "Jonas", "Kofi", "Lena"]
    let family = ["Lima", "Costa", "Novak", "Sato", "Okafor", "Berg", "Moreau", "Kaya", "Silva", "Holm", "Reyes"]
    let cyrillic = [("Иван", "Петров"), ("Анна", "Соколова"), ("Олег", "Морозов")]
    let han = [("伟", "王"), ("芳", "李"), ("磊", "张")]
    return (0..<count).map { index in
        var person = Person(id: "bench-\(index)")
        if index % 7 == 3 {
            person.kind = .organization
            person.organization = "Example Company \(index)"
        } else if index % 20 == 5 {
            (person.givenName, person.familyName) = han[index % han.count]
        } else if index % 10 == 1 {
            (person.givenName, person.familyName) = cyrillic[index % cyrillic.count]
        } else {
            person.givenName = given[index % given.count]
            person.familyName = family[(index / given.count) % family.count] + "\(index)"
        }
        if index % 3 == 0 { person.nickname = "Nick \(index)" }
        if index % 4 == 0 { person.organization = "Example Studio \(index % 50)" }
        person.phones = [LabeledValue("mobile", "+1 555 01\(String(format: "%02d", index % 100))")]
        person.emails = [LabeledValue("work", "person\(index)@example.com")]
        if index % 5 == 0 {
            person.addresses = [PostalAddress(label: "home", street: "\(index) Sample Street", city: "Springfield")]
        }
        return person
    }
}

@Suite("Ten thousand people", .timeLimit(.minutes(2)))
@MainActor
struct ScaleTests {
    @Test func theListOpensAndSearchesTenThousandPeople() async throws {
        let (harness, _) = await makeHarness(people: inventedPeople(10_000))
        try await harness.run("search")
        #expect(harness.rows.count == 10_000)
        try await harness.setQuery("person4321@example.com")
        #expect(harness.selectedRow?.id == ItemID(PeopleSnapshot.namespace, "bench-4321"))
        #expect(try await harness.catalogRows().count == 10_000)
    }
}

/// Times opening Search Contacts over 10,000 invented people. Opt in with
/// `PEOPLE_BENCHMARK=1`, in a release build:
///
///     PEOPLE_BENCHMARK=1 scripts/swiftpm.sh Packages/Features/People test -c release \
///         -Xswiftc -enable-testing --filter PeopleBenchmark
///
/// It prints counts and milliseconds only.
@Suite(
    "Benchmark: 10,000 people", .serialized, .timeLimit(.minutes(10)),
    .enabled(if: ProcessInfo.processInfo.environment["PEOPLE_BENCHMARK"] == "1"))
@MainActor
struct PeopleBenchmark {
    static let people = inventedPeople(10_000)

    /// The first open: the store is read and the snapshot and rows are built, off the main thread.
    /// The very first build in a process also loads the system's transliteration tables, once.
    @Test func openingTheListCold() async throws {
        let first = try await Self.time { _ = await Self.build(Self.people) }
        Self.report("first build in the process, with table loading", [first])
        var samples: [Double] = []
        var stalls: [Double] = []
        var rows = 0
        for _ in 0..<60 {
            let (harness, _) = await makeHarness(people: Self.people)
            let list = harness.feature.list
            let watch = MainThreadWatch()
            watch.start()
            samples.append(
                try await Self.time {
                    let result = try await list.load(ListRequest(reason: .open))
                    rows = result.sections.reduce(0) { $0 + $1.rows.count }
                })
            stalls.append(await watch.stop())
        }
        Self.report("open cold, read and build, wall", samples, extra: "rows=\(rows)")
        Self.report("open cold, longest main-thread stall", stalls)
    }

    /// Later opens, from the snapshot in memory.
    @Test func openingTheListWarm() async throws {
        let (harness, _) = await makeHarness(people: Self.people)
        let list = harness.feature.list
        _ = try await list.load(ListRequest(reason: .open))
        let samples = try await Self.samples(500) { _ = try await list.load(ListRequest(reason: .open)) }
        Self.report("open warm, wall", samples)
    }

    /// The snapshot alone, as a store change rebuilds it.
    @Test func buildingTheSnapshot() async throws {
        let people = Self.people
        let samples = try await Self.samples(60) { _ = await Self.build(people) }
        Self.report("build snapshot and rows, off main", samples)
    }

    /// Root search's rows, cold, as at launch once access was granted.
    @Test func catalogRowsCold() async throws {
        var samples: [Double] = []
        var stalls: [Double] = []
        for _ in 0..<60 {
            let (harness, _) = await makeHarness(people: Self.people)
            let watch = MainThreadWatch()
            watch.start()
            samples.append(try await Self.time { _ = try await harness.catalogRows() })
            stalls.append(await watch.stop())
        }
        Self.report("catalog cold, wall", samples)
        Self.report("catalog cold, longest main-thread stall", stalls)
    }

    @concurrent nonisolated static func build(_ people: [Person]) async -> PeopleSnapshot {
        await PeopleSnapshot.build(people)
    }

    static func time(_ body: () async throws -> Void) async throws -> Double {
        let start = ContinuousClock.now
        try await body()
        return milliseconds(ContinuousClock.now - start)
    }

    static func samples(_ count: Int, _ body: () async throws -> Void) async throws -> [Double] {
        var samples: [Double] = []
        for _ in 0..<count { samples.append(try await time(body)) }
        return samples
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    static func report(_ name: String, _ samples: [Double], extra: String = "") {
        let sorted = samples.sorted()
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let line = String(
            format: "PEOPLE-BENCH %@: n=%d p50=%.2f ms p99=%.2f ms max=%.2f ms %@", name, sorted.count,
            percentile(0.5), percentile(0.99), sorted.last ?? 0, extra)
        print(line)
    }
}

/// Measures the longest time the main actor was busy while a load ran, by stepping a task on it.
@MainActor
final class MainThreadWatch {
    private var task: Task<Double, Never>?
    private var running = true

    func start() {
        task = Task { @MainActor in
            var longest: Double = 0
            var last = ContinuousClock.now
            while self.running {
                await Task.yield()
                let now = ContinuousClock.now
                longest = max(longest, PeopleBenchmark.milliseconds(now - last))
                last = now
            }
            return longest
        }
    }

    func stop() async -> Double {
        running = false
        return await task?.value ?? 0
    }
}
