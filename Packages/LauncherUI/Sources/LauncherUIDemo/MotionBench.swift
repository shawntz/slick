import AppKit
import LauncherUI
import LauncherUITesting

/// Main-thread cost of the two animations: the lens glide and the glass height.
enum MotionBench {
    /// Moves the selection 40 times per lens style, timing the main thread's CPU for the call
    /// plus the commit.
    static func lensGlide() async -> [(style: String, summary: LatencySummary)] {
        var results: [(String, LatencySummary)] = []
        for style in LensMetrics.Style.allCases {
            var theme = Theme.standard
            theme.lens.style = style
            let scene = DemoScene(theme: theme)
            scene.summoner.prewarm()
            scene.summoner.takesKeyStatus = false
            scene.summoner.summon()
            await pause(ms: 50)
            var samples: [Double] = []
            for move in 0..<44 {
                let down = (move / 8) % 2 == 0
                let start = LatencyClock.threadCPUNanoseconds()
                scene.list.moveSelection(by: down ? 1 : -1, animated: true)
                CATransaction.flush()
                if move >= 4 { samples.append(Double(LatencyClock.threadCPUNanoseconds() - start) / 1e6) }
                await pause(ms: 35)
            }
            scene.summoner.dismiss(returnFocus: false)
            scene.surface.panel.orderOut(nil)
            results.append((style.rawValue, LatencySummary(samples)))
            await pause(ms: 500)
        }
        return results
    }

    struct HeightResult {
        var animations = 0
        var ticks = 0
        var cpuPerTick = 0.0
        var longestGap = 0.0
        var refresh = 0.0
    }

    /// Alternates between nine rows with headers and three rows, timing the main thread while
    /// the glass animates and counting display refreshes. In the split layout every tick moves
    /// both pieces, the corner radius, the shadow's path and the rim's mask.
    static func heightAnimation(theme: Theme = .standard) async -> HeightResult {
        let scene = DemoScene(theme: theme)
        scene.summoner.prewarm()
        scene.summoner.takesKeyStatus = false
        let counter = TickCounter(view: scene.surface.rootView)
        let tall = scene.catalog.rootContent()
        var short = scene.catalog.content(for: "aurora")
        short.sections[0].rows = Array(short.sections[0].rows.prefix(3))
        var result = HeightResult()
        var cpu: UInt64 = 0
        for batch in 0..<2 {
            scene.summoner.summon()
            await pause(ms: 80)
            for step in 0..<5 {
                counter.reset()
                let start = LatencyClock.threadCPUNanoseconds()
                scene.list.apply((batch * 5 + step) % 2 == 0 ? short : tall)
                while scene.surface.isAnimatingHeight { await pause(ms: 2) }
                cpu += LatencyClock.threadCPUNanoseconds() - start
                result.ticks += counter.count
                result.longestGap = max(result.longestGap, counter.longestGap)
                result.animations += 1
                await pause(ms: 100)
            }
            scene.summoner.dismiss(returnFocus: false)
            await pause(ms: 600)
        }
        scene.surface.panel.orderOut(nil)
        counter.stop()
        result.cpuPerTick = Double(cpu) / 1e6 / Double(max(1, result.ticks))
        result.refresh = 1000 / Double(max(1, NSScreen.main?.maximumFramesPerSecond ?? 60))
        return result
    }
}

extension MotionBench {
    /// The keystroke that brings the first results after a summon in the compact look, when the
    /// results container of the split layout or the content of one piece shows for the first
    /// time, against the same keystroke on later summons. A fresh scene per round, so every round has a first time. Main-thread
    /// CPU of the content change, the display and the commit, in ms.
    static func firstResults(theme: Theme, rounds: Int = 6) async -> (first: [Double], later: [Double])? {
        var first: [Double] = []
        var later: [Double] = []
        for _ in 0..<rounds {
            let scene = DemoScene(theme: theme)
            scene.surface.setContent(nil, animated: false)
            scene.summoner.prewarm()
            scene.summoner.takesKeyStatus = false
            for show in 0..<3 {
                guard await BenchMode.idle() else {
                    scene.surface.panel.orderOut(nil)
                    return nil
                }
                scene.summoner.summon()
                await pause(ms: 60)
                let start = LatencyClock.threadCPUNanoseconds()
                scene.surface.setContent(scene.list, animated: false)
                scene.show(query: "a")
                scene.surface.panel.displayIfNeeded()
                CATransaction.flush()
                let cpu = Double(LatencyClock.threadCPUNanoseconds() - start) / 1e6
                if show == 0 { first.append(cpu) } else { later.append(cpu) }
                await pause(ms: 120)
                scene.summoner.dismiss(returnFocus: false)
                scene.surface.setContent(nil, animated: false)
                await pause(ms: 200)
            }
            scene.surface.panel.orderOut(nil)
            await pause(ms: 300)
        }
        return (first, later)
    }
}

/// Counts display refreshes and the longest gap between two.
private final class TickCounter: NSObject {
    private(set) var count = 0
    private(set) var longestGap = 0.0
    private var last: CFTimeInterval = 0
    private var link: CADisplayLink?

    init(view: NSView) {
        super.init()
        link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    func reset() {
        count = 0
        longestGap = 0
        last = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        if last > 0 { longestGap = max(longestGap, (link.timestamp - last) * 1000) }
        last = link.timestamp
        count += 1
    }
}
