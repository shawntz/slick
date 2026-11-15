import Foundation
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Testing

@_spi(RootBench) @testable import Root

/// Root search over the real engine in memory, the example features and the fakes.
final class RootFixture {
    let fakes: FakeServices
    let directory = FakeFeatureDirectory()
    let preferences: FakeItemPreferences
    let system = FakeSystemContext()
    let apps: ExampleApps
    let library: LibraryFeature
    /// The feature with async providers, a trigger, a live subtitle and a Tab command, when asked for.
    let signals: SignalsFeature?
    let root: RootSearch

    var clock: FakeClock { fakes.clock }
    var general: FeatureSettings { HostSettings.settings(fakes.settings) }

    init(
        storage: RootStoragePaths = .inMemory, environment: RunEnvironment = .selftest,
        fakes: FakeServices = FakeServices(), apps: ExampleApps = ExampleApps(),
        extraSources: [any CatalogSource] = [], signals: Bool = false,
        offered: (@MainActor (SignalsFeature) -> Void)? = nil,
        seeds: (@Sendable () async -> [LearningSeed])? = nil
    ) {
        self.fakes = fakes
        self.apps = apps
        preferences = FakeItemPreferences(directory: directory)
        library = directory.register(LibraryFeature.self, fakes: fakes)
        directory.register(GardenFeature.self, fakes: fakes)
        if signals {
            let feature = directory.register(SignalsFeature.self, fakes: fakes)
            offered?(feature)
            self.signals = feature
        } else {
            self.signals = nil
        }
        root = RootSearch(
            RootConfiguration(
                directory: directory, preferences: preferences, systemContext: system, settings: fakes.settings,
                clock: fakes.clock, storage: storage, environment: environment,
                builtInSources: [apps] + extraSources, firstRunSeeds: seeds))
    }

    /// Makes a fixture and waits until root search is ready.
    static func ready(
        storage: RootStoragePaths = .inMemory, environment: RunEnvironment = .selftest,
        fakes: FakeServices = FakeServices(), apps: ExampleApps = ExampleApps(),
        extraSources: [any CatalogSource] = [], signals: Bool = false,
        offered: (@MainActor (SignalsFeature) -> Void)? = nil,
        seeds: (@Sendable () async -> [LearningSeed])? = nil
    ) async -> RootFixture {
        let fixture = RootFixture(
            storage: storage, environment: environment, fakes: fakes, apps: apps, extraSources: extraSources,
            signals: signals, offered: offered, seeds: seeds)
        await fixture.root.ready()
        return fixture
    }

    /// The signals feature. Fails the test when the fixture was made without it.
    func signalsFeature() throws -> SignalsFeature {
        try #require(signals, "make the fixture with signals: true")
    }

    /// Lets the async providers' tasks start their debounce, moves the clock past it, and waits until
    /// every provider of the current query delivered.
    func passDebounce(_ wait: Duration = .milliseconds(60)) async {
        for _ in 0..<50 { await Task.yield() }
        clock.advance(by: wait)
        await root.providersFinished()
    }

    /// Waits until every consumer of the fakes and root search's own work are done.
    func settle() async {
        await fakes.settle()
        await system.settle()
        await root.settle()
    }

    /// The titles root search shows for a query, in order, across every section.
    func titles(_ query: String) -> [String] {
        root.update(query: query).rows.map(\.title)
    }

    /// The titles of the engine results for a query.
    func results(_ query: String) -> [String] {
        root.update(query: query).sections.first { $0.kind == .results }?.rows.map(\.title) ?? []
    }

    /// Types a query, then runs the row with this title from what it shows.
    func pick(_ title: String, for query: String, launch: LaunchSource = .root) async throws {
        _ = root.begin()
        let snapshot = root.update(query: query)
        let row = try #require(snapshot.rows.first { $0.title == title }, "\(title) not shown for \(query)")
        root.didRun(row, launch: launch)
        root.end()
        await root.settle()
    }

    func shutdown() async {
        await root.shutdown()
    }
}

/// A fresh folder under the system's temporary directory, removed when the value is released.
final class TemporaryFolder {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appending(path: "root-tests-\(UUID().uuidString)")
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
