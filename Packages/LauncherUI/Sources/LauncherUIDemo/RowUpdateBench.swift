import AppKit
import LauncherUI
import LauncherUITesting

/// The cost of showing nine rows that all changed: the keystroke path's list work.
enum RowUpdateBench {
    /// A scene shown without key status, already showing nine rows.
    private static func makeScene(halo: Bool) -> (scene: DemoScene, contents: [ListContent]) {
        var theme = Theme.standard
        if halo {
            theme.light.textHalo = ThemeColor(.white, alpha: 0.7)
            theme.dark.textHalo = ThemeColor(.black, alpha: 0.7)
        }
        let scene = DemoScene(theme: theme)
        scene.summoner.prewarm()
        scene.summoner.takesKeyStatus = false
        let contents = (0..<8).map { scene.catalog.rotatingContent(step: $0) }
        scene.list.apply(contents[7])
        scene.surface.updateHeight(animated: false)
        scene.summoner.summon()
        return (scene, contents)
    }

    /// Apply, then an explicit display and commit, 160 times about a frame apart. Returns the
    /// main thread's CPU time per update, the budget's measure, and the wall time, which also
    /// counts waiting for the render server to accept the commit.
    static func deterministic(halo: Bool) async -> (cpu: LatencySummary, wall: LatencySummary) {
        let (scene, contents) = makeScene(halo: halo)
        await pause(ms: 50)
        var cpu: [Double] = []
        var wall: [Double] = []
        for step in 0..<180 {
            let cpuStart = LatencyClock.threadCPUNanoseconds()
            let start = LatencyClock.now()
            scene.list.apply(contents[step % contents.count])
            scene.surface.panel.displayIfNeeded()
            CATransaction.flush()
            if step >= 20 {
                wall.append(LatencyClock.ms(start, LatencyClock.now()))
                cpu.append(Double(LatencyClock.threadCPUNanoseconds() - cpuStart) / 1e6)
            }
            await pause(ms: 8)
        }
        scene.summoner.dismiss(returnFocus: false)
        scene.surface.panel.orderOut(nil)
        await pause(ms: 300)
        return (LatencySummary(cpu), LatencySummary(wall))
    }

    /// The same update left to AppKit's own display cycle, timed by the latency probe.
    static func throughDisplayCycle() async -> (cpu: [Double], commit: [Double], frame: [Double]) {
        let (scene, contents) = makeScene(halo: false)
        var records: [LatencyProbe.Record] = []
        let waiter = RecordWaiter()
        scene.summoner.probe.onRecord = {
            if $0.kind == .keystroke { records.append($0) }
            waiter.resume()
        }
        var step = 0
        for batch in 0..<2 {
            if batch > 0 {
                scene.summoner.summon()
                await pause(ms: 50)
            }
            for _ in 0..<40 {
                scene.summoner.probe.begin(.keystroke)
                scene.list.apply(contents[step % contents.count])
                step += 1
                scene.summoner.probe.markApplied()
                await waiter.wait(timeout: 0.1)
                await pause(ms: 12)
            }
            scene.summoner.dismiss(returnFocus: false)
            await pause(ms: 600)
        }
        scene.surface.panel.orderOut(nil)
        let kept = records.dropFirst(5)
        return (kept.map(\.cpuMilliseconds), kept.map(\.handlerToCommit), kept.map(\.handlerToFrameTarget))
    }
}
