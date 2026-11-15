import Foundation
import Kit
import KitTesting
import Testing

@testable import Clipboard

@Suite("Recording copies", .timeLimit(.minutes(1)))
@MainActor
struct MonitorTests {
    @Test func recordsWhatOtherAppsCopy() async throws {
        let clipboard = await ClipboardHarness()
        #expect(clipboard.feature.isMonitoring)
        try await clipboard.copy("first note")
        try await clipboard.copy(
            [.url(Samples.link), .text(Samples.link.absoluteString)], from: ClipboardHarness.browser)
        try await clipboard.copy("no source app", from: nil)
        let page = try await clipboard.store.page(PageRequest())
        #expect(page.items.map(\.kind) == [.text, .link, .text])
        #expect(page.items.map(\.source) == [nil, ClipboardHarness.browser, ClipboardHarness.editor])
        #expect(page.items.last?.copied == clipboard.fakes.clock.now)
    }

    @Test func storesOnlyWhatThePasteboardServiceHandsOver() async throws {
        let fakes = FakeServices()
        let counting = CountingPasteboard(base: fakes.pasteboard)
        var services = fakes.services
        services.pasteboard = counting
        let context = FeatureContext(
            featureID: ClipboardHistoryFeature.manifest.id, environment: .selftest, services: services)
        let harness = FeatureHarness(fakes: fakes) { _ in ClipboardHistoryFeature(context: context) }
        await harness.activate()
        var delivered: [String] = []
        for text in ["one", "two", "three"] {
            delivered.append(fakes.pasteboard.simulateCopy(text, from: ClipboardHarness.editor).plainText ?? "")
            try await harness.settle()
        }
        #expect(counting.readCount == 0, "the monitor never reads the pasteboard itself")
        let store = harness.feature.store
        var stored: [String] = []
        var offset = 0
        while let text = try await store.text(offset: offset) {
            stored.append(text)
            offset += 1
        }
        #expect(stored == delivered.reversed())
        #expect(try await store.count() == delivered.count)
    }

    @Test func handlingACopyNeedsNoMainThread() async throws {
        let clipboard = await ClipboardHarness()
        // One copy first, so the monitor is running and waiting for the next entry.
        try await clipboard.copy("warm up")
        let before = clipboard.feature.changes.generation
        clipboard.pasteboard.simulateCopy("handled while the main thread is blocked", from: ClipboardHarness.editor)
        // Block the main thread without awaiting. The copy can only be recorded if nothing in its
        // path needs the main thread.
        let deadline = ContinuousClock.now + .seconds(10)
        while clipboard.feature.changes.generation == before, ContinuousClock.now < deadline {
            usleep(500)
        }
        #expect(clipboard.feature.changes.generation > before)
        #expect(try await clipboard.store.text(offset: 0) == "handled while the main thread is blocked")
    }

    @Test func ignoredAppsAreNeverRecorded() async throws {
        #expect(ClipboardSettings.ignoredApps.defaultValue.contains("com.apple.Passwords"))
        #expect(ClipboardSettings.ignoredApps.defaultValue.contains("com.apple.keychainaccess"))
        let clipboard = await ClipboardHarness()
        clipboard.settings[ClipboardSettings.ignoredApps] = ["com.example.vault"]
        try await clipboard.copy("secret value", from: "com.example.vault")
        try await clipboard.copy("other secret", from: "COM.Example.Vault")
        try await clipboard.copy("ordinary text")
        #expect(try await clipboard.store.count() == 1)
        #expect(try await clipboard.store.text(offset: 0) == "ordinary text")
        #expect(clipboard.feature.latest.value?.key == ClipboardHarness.textKey("ordinary text"))
    }

    @Test func pausingStopsListeningAndRecordsNothingUntilResumed() async throws {
        let clipboard = await ClipboardHarness()
        clipboard.settings[ClipboardSettings.isPaused] = true
        try await clipboard.harness.settle()
        #expect(!clipboard.feature.isMonitoring)
        try await clipboard.copy("while paused")
        #expect(try await clipboard.store.count() == 0)
        #expect(clipboard.feature.status?.title == Strings.Status.paused)

        clipboard.settings[ClipboardSettings.isPaused] = false
        try await clipboard.harness.settle()
        #expect(clipboard.feature.isMonitoring)
        try await clipboard.copy("after resuming")
        #expect(try await clipboard.store.text(offset: 0) == "after resuming")
        #expect(clipboard.feature.status == nil)
    }

    @Test func aFeatureActivatedWhilePausedDoesNotListen() async throws {
        let fakes = FakeServices()
        ClipboardHarness.settings(fakes)[ClipboardSettings.isPaused] = true
        let clipboard = await ClipboardHarness(fakes: fakes)
        #expect(!clipboard.feature.isMonitoring)
        await clipboard.harness.deactivate()
        #expect(!clipboard.feature.isMonitoring)
    }

    @Test func blankAndOversizedCopiesAreSkipped() async throws {
        let clipboard = await ClipboardHarness()
        try await clipboard.copy("  \n ")
        try await clipboard.copy(String(repeating: "a", count: ClipboardSettings.maximumItemBytes + 1))
        #expect(try await clipboard.store.count() == 0)
    }

    @Test func deactivatingStopsTheMonitor() async throws {
        let clipboard = await ClipboardHarness()
        await clipboard.harness.deactivate()
        #expect(!clipboard.feature.isMonitoring)
        clipboard.pasteboard.simulateCopy("after deactivation", from: ClipboardHarness.editor)
        try await clipboard.harness.settle()
        #expect(try await clipboard.store.count() == 0)
    }

    @Test func withoutPasteboardAccessTheStatusAsksForIt() async throws {
        let fakes = FakeServices()
        fakes.permissions.set(.pasteboard, to: .denied)
        let clipboard = await ClipboardHarness(fakes: fakes)
        #expect(clipboard.feature.status?.requires == [.pasteboard])
        let before = clipboard.feature.declarations.generation
        fakes.permissions.set(.pasteboard, to: .granted)
        try await clipboard.harness.settle()
        #expect(clipboard.feature.declarations.generation > before)
        #expect(clipboard.feature.status == nil)
    }
}
