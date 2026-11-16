import Foundation
import Kit
import KitTesting
import Testing

@testable import Apps

/// Activation scans the app folders and reads the running apps in the background. Scenarios and
/// the self-test wait for `waitUntilReady()` before they type, so it must return only once both
/// have applied.
@Suite("Ready", .timeLimit(.minutes(1)))
@MainActor
struct ReadyTests {
    @Test func waitUntilReadyReturnsOnceTheScanAndTheRunningAppsHaveApplied() async throws {
        let writer = AppsHarness.runningApp(10, "com.example.writer", "Writer")
        let apps = try await AppsHarness(running: [writer])
        let feature: any Feature = apps.feature
        await feature.waitUntilReady()
        #expect(!apps.feature.installed.isEmpty)
        #expect(apps.feature.running == [writer])
    }
}
