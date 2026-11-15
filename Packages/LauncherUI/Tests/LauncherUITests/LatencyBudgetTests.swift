import AppKit
import LauncherUITesting
import QuartzCore
import Testing

@testable import LauncherUI

/// Main-thread budgets from docs/ARCHITECTURE.md, measured deterministically: the work, then an
/// explicit display and commit. Debug builds are 5 to 10 times slower, so these run only in a
/// release build: `swift test -c release` (or `make test-LauncherUI-budget`). A test runner is a
/// terminal process with lower scheduling priority than the app, so these bounds are pessimistic;
/// `LATENCY_BUDGET_SCALE` relaxes them on slower machines. The app-bundle numbers come from
/// `make ui-bench`.
@Suite(.enabled(if: BudgetBuild.isRelease, "budgets run in release builds only"))
struct LatencyBudgetTests {
    let scale = LatencyBudget.environmentScale

    /// The lab's method: drop warm-up samples, then nearest-rank percentiles.
    func measure(_ count: Int, warmUp: Int = 20, _ body: (Int) -> Void) -> LatencySummary {
        var samples: [Double] = []
        samples.reserveCapacity(count)
        for step in 0..<(count + warmUp) {
            let start = LatencyClock.now()
            body(step)
            if step >= warmUp { samples.append(LatencyClock.ms(start, LatencyClock.now())) }
        }
        return LatencySummary(samples)
    }

    @Test func nineChangedRowsFitTheRowUpdateBudget() {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        let list = ResultListView()
        surface.setContent(list, animated: false)
        surface.panel.orderFrontRegardless()
        let catalog = SyntheticCatalog()
        let contents = (0..<8).map { catalog.rotatingContent(step: $0) }
        let summary = measure(300) { step in
            list.apply(contents[step % contents.count])
            surface.panel.displayIfNeeded()
            CATransaction.flush()
        }
        print("row update, 9 changed rows, apply + draw + commit (ms): \(summary)")
        #expect(LatencyBudget.rowUpdate.violation(summary, label: "row update", scale: scale) == nil)
    }

    @Test func summonWithoutMakeKeyFitsTheSummonBudget() {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        let summoner = Summoner(surface: surface)
        summoner.followsPointerScreen = false
        summoner.takesKeyStatus = false
        summoner.prewarm()
        var steps: [Double] = []
        let pointer = measure(200) { _ in _ = LauncherSurface.screenWithPointer()?.visibleFrame }
        let summary = measure(100, warmUp: 5) { _ in
            summoner.summon()
            steps.append(summoner.lastTimings.excludingMakeKey)
            summoner.dismiss(returnFocus: false)
        }
        let path = LatencySummary(Array(steps.dropFirst(5)))
        print(
            "summon path excluding makeKey (ms): \(path); summon + dismiss: \(summary); pointer screen check: \(pointer)"
        )
        // The budget covers the summon path plus the pointer-screen check that precedes it.
        #expect(path.p50 + pointer.p50 <= LatencyBudget.summon.p50 * scale)
        #expect(path.p99 + pointer.p99 <= LatencyBudget.summon.p99 * scale)
    }

    @Test func theProbeCostsMicroseconds() {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        let probe = LatencyProbe(view: surface.rootView)
        let summary = measure(2000) { _ in
            probe.begin(.keystroke)
            probe.markApplied()
        }
        print("probe begin + markApplied (ms): \(summary)")
        #expect(summary.p50 < 0.01 * scale)
    }
}

nonisolated enum BudgetBuild {
    static var isRelease: Bool {
        #if DEBUG
            false
        #else
            true
        #endif
    }
}
