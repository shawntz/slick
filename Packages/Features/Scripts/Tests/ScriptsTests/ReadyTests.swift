import Foundation
import Kit
import KitTesting
import Testing

@testable import Scripts

/// Activation scans the script folders in the background. Scenarios and the self-test wait for
/// `waitUntilReady()` before they type, so it must return only once the scripts are commands.
@Suite("Ready", .timeLimit(.minutes(1)))
@MainActor
struct ReadyTests {
    @Test func waitUntilReadyReturnsOnceTheScriptsAreCommands() async throws {
        let bench = ScriptsBench(files: ["hello.sh": Fixture.script(title: "Say Hello")])
        await bench.harness.activate()
        let feature: any Feature = bench.feature
        await feature.waitUntilReady()
        #expect(bench.scriptCommands.map(\.title) == ["Say Hello"])
    }
}
