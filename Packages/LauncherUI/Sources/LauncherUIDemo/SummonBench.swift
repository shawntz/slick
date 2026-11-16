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
///
/// Every batch takes key status six times, about 120 ms each, so it waits for 120 s without
/// input and stops the moment input arrives.
///
/// Standard is watched in its query row as before. A theme of two pieces is watched in both, in
/// an empty stretch of each, and a summon's times are those of the piece that arrives last.
enum SummonBench {
    struct Result {
        var paths: [Double] = []
        var makeKey: [Double] = []
        var firstPixels: [Double] = []
        var keyLook: [Double] = []
        /// Per summon, the progress from hidden (0) to key look (1) of each displayed frame.
        var trajectories: [[Double]] = []
        /// True when input arrived and the run stopped early.
        var interrupted = false
    }

    static func run(
        strategy: SummonStrategy, rampFrames: Int, keyFirst: Bool, cycles: Int, theme base: Theme = .standard
    ) async -> Result {
        var theme = base
        theme.motion.summonRampFrames = rampFrames
        let scene = DemoScene(theme: theme, strategy: strategy)
        scene.summoner.makesKeyBeforeShowing = keyFirst
        scene.summoner.prewarm()
        await pause(ms: 150)
        let regions = watchedRegions(scene.surface)
        var result = Result()
        var done = 0
        while done < cycles {
            let count = min(6, cycles - done)
            // Each batch takes key status six times, so it waits until nobody is typing.
            guard await IdleGate.wait(seconds: 120, interval: 1, until: Date().addingTimeInterval(1800)) else { break }
            let watch = IdleGuard.Watch()
            watch.onInput = {
                result.interrupted = true
                scene.summoner.dismiss(returnFocus: true)
            }
            watch.start()
            // The stream only includes windows that are ordered in when it starts.
            if strategy == .orderFront { scene.surface.panel.orderFrontRegardless() }
            let watcher = FrameWatcher()
            try? await watcher.start(screenRect: scene.windowFrame, regions: regions)
            if strategy == .orderFront { scene.surface.panel.orderOut(nil) }
            await pause(ms: 150)
            var starts: [UInt64] = []
            for _ in 0..<count where !result.interrupted {
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
            watch.stop()
            if result.interrupted || watch.inputArrived {
                result.interrupted = true
                break
            }
            analyse(watcher.snapshot(), starts: starts, regions: regions.count, into: &result)
            done += count
            await pause(ms: 600)
        }
        scene.surface.panel.orderOut(nil)
        return result
    }

    /// Empty stretches of glass in window coordinates, top-down: Standard's place in the query
    /// row, or the middle of the capsule and of a row's free stretch in a split theme.
    static func watchedRegions(_ surface: LauncherSurface) -> [CGRect] {
        let theme = surface.theme
        let insets = theme.panel.shadowInsets
        guard theme.panel.layout == .split else {
            return [CGRect(x: insets.left + 420, y: insets.top + 16, width: 260, height: 28)]
        }
        let field = surface.geometry.fieldFrame
        let list = theme.list
        let row = surface.geometry.resultsTop + list.verticalPadding + list.rowHeight * 2
        return [
            CGRect(x: field.minX + field.width * 0.55, y: field.midY - 14, width: field.width * 0.25, height: 28),
            CGRect(x: field.minX + field.width * 0.6, y: row + 10, width: field.width * 0.2, height: 28),
        ]
    }

    private static func analyse(
        _ frames: [FrameWatcher.Frame], starts: [UInt64], regions: Int, into result: inout Result
    ) {
        let ticks = { (ms: Double) in LatencyClock.ticks(seconds: ms / 1000) }
        for start in starts {
            let after = frames.filter { $0.displayTime >= start && $0.displayTime < start + ticks(115) }
            var firstPixels: Double?
            var keyLook: Double?
            var trajectory: [Double]?
            var complete = true
            for region in 0..<regions {
                guard let hidden = frames.last(where: { $0.displayTime < start })?.luminance[region],
                    let key = after.last(where: { $0.displayTime > start + ticks(80) })?.luminance[region],
                    abs(key - hidden) > 0.02
                else {
                    complete = false
                    break
                }
                let progress = after.map {
                    (time: $0.displayTime, value: ($0.luminance[region] - hidden) / (key - hidden))
                }
                if let first = progress.first(where: { $0.value >= 0.3 }) {
                    firstPixels = max(firstPixels ?? 0, LatencyClock.ms(start, first.time))
                }
                if let full = progress.first(where: { $0.value >= 0.85 }) {
                    keyLook = max(keyLook ?? 0, LatencyClock.ms(start, full.time))
                }
                // The trajectory of the piece that settles last.
                let values = progress.map(\.value).filter { $0 > 0.05 }
                if trajectory == nil || values.count > (trajectory?.count ?? 0) { trajectory = values }
            }
            guard complete else { continue }
            if let firstPixels { result.firstPixels.append(firstPixels) }
            if let keyLook { result.keyLook.append(keyLook) }
            if let trajectory { result.trajectories.append(trajectory) }
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
