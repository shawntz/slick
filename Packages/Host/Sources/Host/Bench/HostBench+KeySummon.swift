import AppKit
import Foundation
import IOKit
import LauncherUI

#if SCENARIO_RECORDING
    import LauncherUITesting
#endif

extension HostBench {
    /// How many summons with key status the bench makes, in batches.
    static let keySummonBatches = 5
    static let keySummonsPerBatch = 6
    /// Seconds without keyboard or mouse input before each batch.
    static let keySummonIdle: Double = 30

    /// Summons the way the live launcher does: with key status, in the summoner's order, which
    /// makes the panel key and commits the glass's key look before the first visible frame unless
    /// `makesKeyBeforeShowing` is false. Records, per summon: the summoner's own path without
    /// `makeKey` and the key look's commit, which the 1 ms budget covers; `makeKey` and the key
    /// look alone, both wall time; and the main thread's CPU time for the whole summon, the host's
    /// part included. A build made with `SCENARIO_RECORDING=1` also watches the frames the window
    /// server shows and records first pixels: the first frame 30% of the way from hidden to the
    /// finished look, and the finished look, the first frame past 85%.
    ///
    /// Each summon holds key status for about 120 ms, and key events from the hardware are dropped
    /// meanwhile. Each batch of six waits for 30 s without input first, and the bench stops before
    /// the next summon once input arrives.
    func keySummons() async {
        let summoner = panel.summoner
        let takesKey = summoner.takesKeyStatus
        summoner.takesKeyStatus = true
        // A key pressed while the panel is key would type into it; drop it, as scenarios do.
        let keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { _ in nil }
        defer {
            summoner.takesKeyStatus = takesKey
            if let keys { NSEvent.removeMonitor(keys) }
        }
        var paths: [Double] = []
        var cpus: [Double] = []
        var makeKeys: [Double] = []
        var looks: [Double] = []
        var firstPixels: [Double] = []
        var finished: [Double] = []
        var stopped: String?
        for _ in 0..<Self.keySummonBatches {
            guard await Self.waitForIdle(seconds: Self.keySummonIdle, within: .seconds(120)) else {
                stopped = "no 30 s without input within 2 minutes"
                break
            }
            let idleBefore = Self.idleSeconds() ?? 0
            let started = Date()
            #if SCENARIO_RECORDING
                let insets = panel.surface.theme.panel.shadowInsets
                let interior = CGRect(x: insets.left + 420, y: insets.top + 16, width: 260, height: 28)
                let watcher = FrameWatcher()
                try? await watcher.start(screenRect: panel.surface.panel.frame, regions: [interior])
                await pause(150)
            #endif
            var starts: [UInt64] = []
            for _ in 0..<Self.keySummonsPerBatch {
                if Self.inputArrived(since: started, idleBefore: idleBefore) { break }
                starts.append(LatencyClock.now())
                let start = LatencyClock.threadCPUNanoseconds()
                panel.summon()
                cpus.append(Double(LatencyClock.threadCPUNanoseconds() - start) / 1e6)
                let timings = summoner.lastTimings
                paths.append(timings.excludingMakeKey)
                makeKeys.append(timings.makeKey)
                looks.append(timings.keyLook)
                await pause(120)
                panel.dismiss()
                await pause(160)
            }
            #if SCENARIO_RECORDING
                await watcher.stop()
                Self.firstPixels(watcher.snapshot(), starts: starts, first: &firstPixels, finished: &finished)
            #endif
            _ = starts
            if Self.inputArrived(since: started, idleBefore: idleBefore) {
                stopped = "input arrived, so the bench stopped"
                break
            }
            await pause(600)
        }
        let order = summoner.makesKeyBeforeShowing ? "key first" : "shown first"
        add(
            "summon with key status, minus makeKey and key look", paths, budget: LatencyBudget(p50: 1, p99: 1),
            note: [order, stopped].compactMap(\.self).joined(separator: "; "))
        add("summon with key status, main-thread CPU", cpus, budget: nil, note: "the whole summon, the host's part too")
        add("summon makeKey", makeKeys, budget: nil, note: "window server time, outside the budget")
        add("summon key look commit", looks, budget: nil, note: "AppKit's layout of the key look, before the flip")
        if firstPixels.isEmpty {
            add("summon first pixels", [], budget: nil, note: "only a SCENARIO_RECORDING build watches frames")
        } else {
            add("summon first pixels", firstPixels, budget: nil, note: "wall time from the hotkey's call to the frame")
            add("summon finished look", finished, budget: nil, note: "first frame past 85% of the key look")
        }
    }

    #if SCENARIO_RECORDING
        /// For each summon, the first frame 30% of the way from hidden to the key look, and the
        /// first past 85%, in ms after the summon started. A summon without a clear change in the
        /// watched stretch of the query row is left out.
        static func firstPixels(
            _ frames: [FrameWatcher.Frame], starts: [UInt64], first: inout [Double], finished: inout [Double]
        ) {
            let ticks = { (ms: Double) in LatencyClock.ticks(seconds: ms / 1000) }
            for start in starts {
                let after = frames.filter { $0.displayTime >= start && $0.displayTime < start + ticks(115) }
                guard let hidden = frames.last(where: { $0.displayTime < start })?.luminance.first,
                    let key = after.last(where: { $0.displayTime > start + ticks(80) })?.luminance.first,
                    abs(key - hidden) > 0.02
                else { continue }
                let progress = after.map {
                    ($0.displayTime, (($0.luminance.first ?? hidden) - hidden) / (key - hidden))
                }
                if let frame = progress.first(where: { $0.1 >= 0.3 }) { first.append(LatencyClock.ms(start, frame.0)) }
                if let frame = progress.first(where: { $0.1 >= 0.85 }) {
                    finished.append(LatencyClock.ms(start, frame.0))
                }
            }
        }
    #endif

    /// True when someone touched the Mac since `started`: the idle time grew less than the time
    /// that passed.
    static func inputArrived(since started: Date, idleBefore: Double) -> Bool {
        guard let idle = idleSeconds() else { return false }
        return idle + 0.5 < idleBefore + Date().timeIntervalSince(started)
    }

    /// Seconds since the last keyboard or mouse input, from `HIDIdleTime`. Nil when unreadable.
    nonisolated static func idleSeconds() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard
            let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()
        else { return nil }
        if let number = value as? NSNumber { return number.doubleValue / 1_000_000_000 }
        return nil
    }

    /// Waits until nobody has touched the Mac for `seconds`, looking twice a second, for at most
    /// `limit`. True when that happened.
    static func waitForIdle(seconds: Double, within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if let idle = idleSeconds(), idle >= seconds { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }
}
