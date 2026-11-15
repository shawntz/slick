import AppKit
import LauncherUI
import LauncherUITesting

/// Summons with key status while a ScreenCaptureKit stream records when the window server
/// displays each frame, and reads the glass's luminance in an empty stretch of the query row.
///
/// With nothing behind the panel, an own-process capture shows three distinct levels: hidden
/// (flat grey), the flatter look of a glass that is not yet key, and the full key look. First
/// pixels are the first frame 30% of the way from hidden to the key look; the key look is the
/// first frame past 85%. The trajectory shows how each summon gets there, frame by frame.
enum SummonBench {
    struct Result {
        var paths: [Double] = []
        var makeKey: [Double] = []
        var firstPixels: [Double] = []
        var keyLook: [Double] = []
        /// Per summon, the progress from hidden (0) to key look (1) of each displayed frame.
        var trajectories: [[Double]] = []
    }

    static func run(strategy: SummonStrategy, rampFrames: Int, cycles: Int) async -> Result {
        var theme = Theme.standard
        theme.motion.summonRampFrames = rampFrames
        let scene = DemoScene(theme: theme, strategy: strategy)
        scene.summoner.prewarm()
        await pause(ms: 150)
        let insets = theme.panel.shadowInsets
        let interior = CGRect(x: insets.left + 420, y: insets.top + 16, width: 260, height: 28)
        var result = Result()
        var done = 0
        while done < cycles {
            let count = min(6, cycles - done)
            // Each batch takes key status six times, so it waits until nobody is typing.
            guard await IdleGate.wait(seconds: 15, until: Date().addingTimeInterval(1800)) else { break }
            // The stream only includes windows that are ordered in when it starts.
            if strategy == .orderFront { scene.surface.panel.orderFrontRegardless() }
            let watcher = FrameWatcher()
            try? await watcher.start(screenRect: scene.windowFrame, regions: [interior])
            if strategy == .orderFront { scene.surface.panel.orderOut(nil) }
            await pause(ms: 150)
            var starts: [UInt64] = []
            for _ in 0..<count {
                scene.summoner.takesKeyStatus = true
                starts.append(LatencyClock.now())
                scene.summoner.summon()
                result.paths.append(scene.summoner.lastTimings.excludingMakeKey)
                result.makeKey.append(scene.summoner.lastTimings.makeKey)
                await pause(ms: 120)
                scene.summoner.dismiss(returnFocus: true)
                await pause(ms: 160)
            }
            await watcher.stop()
            analyse(watcher.snapshot(), starts: starts, into: &result)
            done += count
            await pause(ms: 600)
        }
        scene.surface.panel.orderOut(nil)
        return result
    }

    private static func analyse(_ frames: [FrameWatcher.Frame], starts: [UInt64], into result: inout Result) {
        let ticks = { (ms: Double) in LatencyClock.ticks(seconds: ms / 1000) }
        for start in starts {
            let after = frames.filter { $0.displayTime >= start && $0.displayTime < start + ticks(115) }
            guard let hidden = frames.last(where: { $0.displayTime < start })?.luminance[0],
                let key = after.last(where: { $0.displayTime > start + ticks(80) })?.luminance[0],
                abs(key - hidden) > 0.02
            else { continue }
            let progress = after.map { (time: $0.displayTime, value: ($0.luminance[0] - hidden) / (key - hidden)) }
            if let first = progress.first(where: { $0.value >= 0.3 }) {
                result.firstPixels.append(LatencyClock.ms(start, first.time))
            }
            if let full = progress.first(where: { $0.value >= 0.85 }) {
                result.keyLook.append(LatencyClock.ms(start, full.time))
            }
            result.trajectories.append(progress.map(\.value).filter { $0 > 0.05 })
        }
    }

    /// The median progress of the first `count` visible frames, across summons.
    static func medianTrajectory(_ trajectories: [[Double]], count: Int = 5) -> [Double] {
        (0..<count).map { index in
            let values = trajectories.compactMap { index < $0.count ? $0[index] : nil }.sorted()
            return values.isEmpty ? .nan : values[values.count / 2]
        }
    }
}
