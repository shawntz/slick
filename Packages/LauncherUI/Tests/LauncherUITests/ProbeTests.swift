import AppKit
import LauncherUITesting
import Testing

@testable import LauncherUI

@Suite(.timeLimit(.minutes(1)))
struct ProbeTests {
    /// A 1×1 transparent window on screen, so the display link ticks. Nothing is visible.
    func makeOnScreenView() -> (view: NSView, window: NSWindow) {
        _ = NSApplication.shared
        let frame = NSScreen.main?.frame ?? .zero
        let window = NSWindow(
            contentRect: CGRect(x: frame.minX, y: frame.minY, width: 1, height: 1), styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        window.contentView = view
        window.orderFrontRegardless()
        return (view, window)
    }

    @Test func recordsCommitAndFrameForEachInteraction() async {
        let (view, window) = makeOnScreenView()
        defer { window.close() }
        let probe = LatencyProbe(view: view)
        var records: [LatencyProbe.Record] = []
        probe.onRecord = { records.append($0) }
        for step in 0..<10 {
            probe.begin(.keystroke)
            view.needsDisplay = true
            probe.markApplied()
            // The loop ends the moment the frame lands. The deadline only bounds a machine whose
            // display link is slow to tick, such as a hosted runner's virtual display.
            let deadline = LatencyClock.now() + LatencyClock.ticks(seconds: 5)
            while records.count <= step && LatencyClock.now() < deadline {
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        #expect(records.count >= 9, "completed \(records.count) of 10")
        #expect(
            records.allSatisfy {
                $0.isComplete && $0.handler <= $0.applied && $0.applied <= $0.committed && $0.committed <= $0.frame
            })
        // An interaction that missed its deadline under load stays in the ring, incomplete.
        #expect(probe.records(.keystroke).filter(\.isComplete).count == records.count)
    }

    @Test func anInterruptedInteractionIsKeptIncomplete() {
        let (view, window) = makeOnScreenView()
        defer { window.close() }
        let probe = LatencyProbe(view: view)
        probe.begin(.summon)
        probe.begin(.keystroke)
        let kept = probe.records()
        #expect(kept.count == 1)
        #expect(kept.first?.kind == .summon)
        #expect(kept.first?.isComplete == false)
    }

    @Test func percentilesUseNearestRank() {
        let summary = LatencySummary((1...100).map(Double.init))
        #expect(summary.p50 == 50)
        #expect(summary.p99 == 99)
        #expect(summary.min == 1 && summary.max == 100)
        #expect(LatencyBudget(p50: 40, p99: 200).violation(summary, label: "x") != nil)
        #expect(LatencyBudget(p50: 50, p99: 99).violation(summary, label: "x") == nil)
    }
}
