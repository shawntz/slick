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
    /// the glass animates and counting display refreshes.
    static func heightAnimation() async -> HeightResult {
        let scene = DemoScene()
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
