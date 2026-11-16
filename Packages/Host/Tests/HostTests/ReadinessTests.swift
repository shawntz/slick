import Foundation
import Host
import Kit
import KitTesting
import Testing

/// A feature whose activation starts work that search depends on, held until the test lets it go.
@MainActor final class SlowLoader: Feature {
    static let manifest = FeatureManifest(id: "slow-loader", name: "Slow Loader", icon: .symbol("hourglass"))
    private(set) var waits = 0
    var release: CheckedContinuation<Void, Never>?

    init(context: FeatureContext) {}

    func waitUntilReady() async {
        waits += 1
        await withCheckedContinuation { release = $0 }
    }
}

/// The same, but off until the user turns it on.
@MainActor final class OffLoader: Feature {
    static let manifest = FeatureManifest(
        id: "off-loader", name: "Off Loader", icon: .symbol("hourglass"), isEnabledByDefault: false)
    private(set) var waits = 0

    init(context: FeatureContext) {}

    func waitUntilReady() async { waits += 1 }
}

@Suite("Runtime: readiness", .timeLimit(.minutes(1)))
@MainActor struct ReadinessTests {
    @Test func waitingForReadinessWaitsForEveryActiveFeatureAndNoOther() async throws {
        let fakes = FakeServices()
        let runtime = FeatureRuntime(
            services: fakes.services, environment: .selftest,
            dataDirectory: fakes.storage.root.appending(path: "host", directoryHint: .isDirectory))
        await runtime.start([FeatureRegistration(SlowLoader.self), FeatureRegistration(OffLoader.self)])
        let loader = try #require(runtime.instance("slow-loader") as? SlowLoader)
        let off = try #require(runtime.instance("off-loader") as? OffLoader)

        let finished = Box(false)
        let wait = Task {
            await runtime.waitUntilFeaturesAreReady()
            finished.value = true
        }
        while loader.release == nil { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        #expect(!finished.value)
        loader.release?.resume()
        await wait.value
        #expect(finished.value)
        #expect(loader.waits == 1)
        #expect(off.waits == 0)
    }

    @Test func aFeatureWithoutWorkIsReadyAtOnce() async {
        let fixture = RuntimeFixture()
        await fixture.start()
        await fixture.runtime.waitUntilFeaturesAreReady()
    }
}
