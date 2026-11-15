import AppKit
import Foundation
import Host
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import QuartzCore
import Testing

/// Host budgets as main-thread CPU time in a release build, with a root source that returns 50
/// rows from a 10,000-row list. Debug builds are 5 to 10 times slower, so these run only in a
/// release build: `scripts/swiftpm.sh Packages/Host test -c release --filter BudgetTests`.
/// `LATENCY_BUDGET_SCALE` relaxes them on slower machines.
///
/// - The host's own work per keystroke, on top of Root's query and LauncherUI's drawing: 0.5 ms p99.
/// - Summon, excluding `makeKey`: 1 ms p99.
/// - Opening the action panel, including its draw and commit: 8 ms p99.
@Suite("Budgets", .serialized, .enabled(if: BudgetBuild.isRelease, "budgets run in release builds only"))
@MainActor struct BudgetTests {
    let scale = LatencyBudget.environmentScale

    private func makePanel() async -> (PanelController, BenchRootSource, RuntimeFixture) {
        _ = NSApplication.shared
        let runtime = RuntimeFixture()
        await runtime.start()
        let root = BenchRootSource()
        let surface = LauncherSurface(visibleFrame: PanelFixture.offscreen)
        surface.panel.appearance = NSAppearance(named: .aqua)
        surface.accessibilityOverride = DisplayAccessibility(reduceMotion: true)
        let panel = PanelController(
            runtime: runtime.runtime, rootSource: root, icons: FakeIconProvider(), surface: surface, hud: RecordingHUD()
        )
        panel.summoner.takesKeyStatus = false
        panel.summoner.followsPointerScreen = false
        panel.prewarm()
        panel.summon()
        return (panel, root, runtime)
    }

    private static let queries = ["s", "sa", "sam", "samp", "sampl", "sample", "sampl", "samp", "sam", "sa"]

    @Test func keystrokeHostWorkFitsHalfAMillisecond() async {
        let (panel, _, runtime) = await makePanel()
        defer { panel.surface.panel.close() }
        _ = runtime
        let field = panel.surface.queryField
        let meter = panel.workMeter
        meter.isEnabled = true
        var host: [Double] = []
        var handler: [Double] = []
        var whole: [Double] = []
        let warmUp = 30
        for step in 0..<(400 + warmUp) {
            let text = Self.queries[step % Self.queries.count]
            field.text = text
            meter.reset()
            let start = LatencyClock.threadCPUNanoseconds()
            panel.queryField(field, didChangeText: text)
            let handled = LatencyClock.threadCPUNanoseconds()
            panel.surface.panel.displayIfNeeded()
            CATransaction.flush()
            let committed = LatencyClock.threadCPUNanoseconds()
            guard step >= warmUp else { continue }
            let handlerNanoseconds = handled - start
            host.append(Double(handlerNanoseconds &- meter.calledNanoseconds) / 1e6)
            handler.append(Double(handlerNanoseconds) / 1e6)
            whole.append(Double(committed - start) / 1e6)
        }
        meter.isEnabled = false
        let hostSummary = LatencySummary(host)
        print("keystroke, host's own work (ms CPU): \(hostSummary)")
        print("keystroke, handler incl. Root update and LauncherUI apply (ms CPU): \(LatencySummary(handler))")
        print("keystroke, handler + draw + commit, no field editor (ms CPU): \(LatencySummary(whole))")
        #expect(hostSummary.p99 <= 0.5 * scale, "host work per keystroke: \(hostSummary)")
    }

    @Test func summonWithoutMakeKeyFitsAMillisecond() async {
        let (panel, _, runtime) = await makePanel()
        defer { panel.surface.panel.close() }
        _ = runtime
        panel.dismiss()
        var samples: [Double] = []
        var lap: [Double] = []
        let warmUp = 10
        for step in 0..<(200 + warmUp) {
            let start = LatencyClock.threadCPUNanoseconds()
            panel.summon()
            let cpu = Double(LatencyClock.threadCPUNanoseconds() - start) / 1e6
            if step >= warmUp {
                samples.append(cpu - panel.summoner.lastTimings.makeKey)
                lap.append(panel.summoner.lastTimings.excludingMakeKey)
            }
            panel.dismiss()
        }
        // The production panel also checks the screen under the pointer first; count it as CPU.
        let pointer = (0..<200).map { _ in
            let start = LatencyClock.threadCPUNanoseconds()
            _ = LauncherSurface.screenWithPointer()?.visibleFrame
            return Double(LatencyClock.threadCPUNanoseconds() - start) / 1e6
        }
        let summary = LatencySummary(samples)
        let pointerSummary = LatencySummary(pointer)
        print("summon, whole path minus makeKey (ms CPU): \(summary)")
        print("summon, Summoner's own steps (ms wall): \(LatencySummary(lap))")
        print("summon, pointer screen check (ms CPU): \(pointerSummary)")
        #expect(summary.p99 + pointerSummary.p99 <= 1 * scale, "summon: \(summary)")
    }

    @Test func openingTheActionPanelFitsAFrame() async {
        let (panel, _, runtime) = await makePanel()
        defer { panel.surface.panel.close() }
        _ = runtime
        let field = panel.surface.queryField
        field.text = "sa"
        panel.queryField(field, didChangeText: "sa")
        var samples: [Double] = []
        let warmUp = 10
        for step in 0..<(120 + warmUp) {
            let start = LatencyClock.threadCPUNanoseconds()
            panel.openActionPanel()
            panel.surface.panel.displayIfNeeded()
            CATransaction.flush()
            let cpu = Double(LatencyClock.threadCPUNanoseconds() - start) / 1e6
            if step >= warmUp { samples.append(cpu) }
            panel.surface.dismissOverlay()
            panel.surface.panel.displayIfNeeded()
            CATransaction.flush()
            // Alternate the selected row, so each opening builds a different panel.
            _ = panel.queryField(field, perform: step.isMultiple(of: 2) ? .moveDown : .moveUp)
        }
        let summary = LatencySummary(samples)
        print("action panel open, build + present + draw + commit (ms CPU): \(summary)")
        #expect(panel.actionEntries.count > 5)
        #expect(summary.p99 <= 8 * scale, "action panel: \(summary)")
    }

    /// Pushing a page, filtering 3,000 grid cells and a detail append, through ``HostBench``.
    @Test func pushGridAndDetailFitTheirBudgets() async {
        let (panel, _, runtime) = await makePanel()
        defer { panel.surface.panel.close() }
        _ = runtime
        let bench = HostBench(panel: panel, placesInCorner: false)
        bench.log = { _ in }
        let passed = await bench.run(["push", "grid", "detail"])
        print(bench.table())
        #expect(bench.lines.count == 7)
        #expect(passed, "\(bench.table())")
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
