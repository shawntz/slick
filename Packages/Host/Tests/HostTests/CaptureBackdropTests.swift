import AppKit
import Foundation
import Host
import Kit
import Testing

/// A backdrop that records what the runner asks of it and never goes on screen: ordering it in is
/// recorded instead of done.
@MainActor final class RecordingBackdrop: NSWindow {
    private(set) var events: [String] = []
    private(set) var orderedAt: ContinuousClock.Instant?

    override func orderFrontRegardless() {
        events.append("order in")
        orderedAt = .now
    }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWindow: Int) {
        events.append(place == .below ? "order below" : "order")
    }

    override func displayIfNeeded() {
        events.append("draw")
        super.displayIfNeeded()
    }
}

/// A capture over a backdrop draws the backdrop and waits for the window server before the picture,
/// with or without key status, so the picture never shows the Mac's desktop.
@Suite("Scenario: capture over a backdrop", .serialized, .timeLimit(.minutes(1)))
@MainActor struct CaptureBackdropTests {
    @Test func theBackdropDrawsAndSettlesBeforeThePicture() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let output = FileManager.default.temporaryDirectory.appending(
            path: "capture-backdrop-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: output) }
        let runner = ScenarioRunner(panel: fixture.panel, output: output, placesInCorner: false)
        let backdrop = RecordingBackdrop(
            contentRect: PanelFixture.offscreen, styleMask: .borderless, backing: .buffered, defer: true)
        backdrop.isReleasedWhenClosed = false
        runner.makeBackdrop = { _ in backdrop }
        let seen = Box<[String]>([])
        let waited = Box<Duration?>(nil)
        runner.capture = { _ in
            seen.value = backdrop.events
            waited.value = backdrop.orderedAt.map { ContinuousClock.now - $0 }
            return ScenarioTests.solidImage()
        }
        let result = await runner.run(Scenario(name: "backdrop", steps: [.capture(name: "plain", key: false)]))
        #expect(result.passed, "\(result.reason ?? "")")
        // AppKit may draw it again during the pause; the runner's own draw comes first.
        #expect(Array(seen.value.prefix(3)) == ["order in", "order below", "draw"], "\(seen.value)")
        let pause = try #require(waited.value)
        // The runner settles for 120 ms; a lower bound holds however loaded the Mac is.
        #expect(pause >= .milliseconds(100), "the settle pause runs without key status too")
    }
}
