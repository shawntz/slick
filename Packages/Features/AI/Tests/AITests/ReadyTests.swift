import Foundation
import Kit
import KitTesting
import Testing

@testable import AI

/// Activation reads the user's commands in the background. Scenarios and the self-test wait for
/// `waitUntilReady()` before they type, so it must return only once those commands are known.
@Suite("Ready", .timeLimit(.minutes(1)))
@MainActor
struct ReadyTests {
    @Test func waitUntilReadyReturnsOnceTheUsersCommandsAreRead() async throws {
        let ai = try await AIHarness(activate: false)
        let url = ai.harness.context.storage.dataFile(AIFeature.commandsFileName)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"commands": [{"title": "Shorten Note", "prompt": "Shorten {selection}"}]}"#.utf8).write(to: url)
        await ai.harness.activate()
        let feature: any Feature = ai.feature
        await feature.waitUntilReady()
        #expect(ai.feature.customCommands.map(\.title) == ["Shorten Note"])
        #expect(ai.harness.issues.isEmpty)
    }
}
