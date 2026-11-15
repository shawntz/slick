import AppKit
import LauncherUI
import LauncherUITesting

/// Records summons with the clip recorder over the dark and light product wallpapers, and counts
/// the frames that showed the glass before its key look, with the panel made key first (the
/// default) and shown first (the old order).
///
///   flash [tones=dark,light] [summons=20] [batch=4] [idle=120] [clips=1]
///
/// Every summon takes key status for about 150 ms. Each batch waits for `idle` seconds without
/// input, stays on screen under two seconds, and stops the moment input arrives. The two orders
/// take turns, batch by batch, so they see the same load. With `clips=1` each batch is also
/// written as an MP4 under `<out>/flash`.
enum FlashMode {
    static let orders: [(name: String, keyFirst: Bool)] = [("show first", false), ("key first", true)]

    /// Frames from the recorder's queue.
    nonisolated final class Samples: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [SummonLookMeter.Sample] = []
        func append(_ sample: SummonLookMeter.Sample) { lock.withLock { items.append(sample) } }
        var all: [SummonLookMeter.Sample] { lock.withLock { items } }
    }

    struct Measured {
        var looks: [SummonLookMeter.Result] = []
        var paths: [Double] = []
        var makeKey: [Double] = []
        var keyLook: [Double] = []
        /// The probe's main-thread CPU from the summon to its commit, which includes work that
        /// runs after `summon()` returns.
        var toCommit: [Double] = []

        static func + (lhs: Measured, rhs: Measured) -> Measured {
            Measured(
                looks: lhs.looks + rhs.looks, paths: lhs.paths + rhs.paths, makeKey: lhs.makeKey + rhs.makeKey,
                keyLook: lhs.keyLook + rhs.keyLook, toCommit: lhs.toCommit + rhs.toCommit)
        }
    }

    static func run(_ options: DemoOptions) async -> Bool {
        let out = options.outputDirectory.appendingPathComponent("flash")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let tones = options.string("tones", "dark,light").split(separator: ",").compactMap {
            ShowcaseMode.Tone(rawValue: String($0))
        }
        let summons = options.int("summons", 20)
        let batch = max(1, min(5, options.int("batch", 4)))
        let idleNeeded = max(120, options.double("idle", 120))
        let clips = options.int("clips", 1) == 1
        let deadline = Date().addingTimeInterval(options.double("idleBudget", 1800))
        guard let screen = NSScreen.main, !tones.isEmpty else {
            say("flash: no screen, or no tone in dark, light")
            return false
        }
        let size = ShowcaseMode.canvasSize(marginX: 90, marginY: 70, theme: .standard)
        let canvas = CGRect(origin: CGPoint(x: screen.frame.minX, y: screen.frame.minY), size: size)
        let scene = DemoScene()
        scene.surface.queryField.delegate = nil
        let stage = ShowcaseStage(scene: scene)
        scene.summoner.prewarm()
        stage.reset()
        stage.showSuggestions()
        stage.center(in: canvas, lift: 6)
        scene.surface.updateHeight(animated: false)
        let scale = screen.backingScaleFactor

        var measured: [String: Measured] = [:]
        var longest = 0.0
        for tone in tones {
            let wallpaper = ShowcaseArt.render(
                tone.wallpaper, pixels: CGSize(width: size.width * scale, height: size.height * scale))
            guard await IdleGate.wait(seconds: idleNeeded, until: deadline) else { return false }
            await CaptureSupport.setAppearance(tone.appearance, scene)
            for round in 0..<((summons + batch - 1) / batch) {
                for order in orders {
                    guard await IdleGate.wait(seconds: idleNeeded, interval: 1, until: deadline) else { return false }
                    scene.summoner.makesKeyBeforeShowing = order.keyFirst
                    let file = "\(tone)-\(order.keyFirst ? "key-first" : "show-first")-\(round).mp4"
                    guard
                        let outcome = await recordBatch(
                            count: min(batch, summons - round * batch), scene: scene, canvas: canvas,
                            wallpaper: wallpaper, clip: clips ? out.appendingPathComponent(file) : nil)
                    else {
                        say("flash: input arrived; the panel was put away and the run stopped")
                        scene.summoner.makesKeyBeforeShowing = true
                        scene.surface.panel.orderOut(nil)
                        return false
                    }
                    longest = max(longest, outcome.onScreen)
                    measured["\(tone) \(order.name)"] =
                        (measured["\(tone) \(order.name)"] ?? Measured()) + outcome.measured
                }
            }
        }
        scene.summoner.makesKeyBeforeShowing = true
        scene.surface.panel.orderOut(nil)

        var table = TextTable([
            "tone", "order", "n", "summons with 0/1/2/3+ flat frames", "flat ms mean / max", "first pixels p50/p99",
            "key look p50/p99", "path excl. makeKey p50/p99", "makeKey p50/p99", "glass key layout p50/p99",
            "CPU to commit p50/p99", "levels of summon 1",
        ])
        for tone in tones {
            for order in orders {
                let result = measured["\(tone) \(order.name)"] ?? Measured()
                var histogram = [0, 0, 0, 0]
                for look in result.looks { histogram[min(3, look.flatFrames)] += 1 }
                let flat = result.looks.map(\.flatMilliseconds)
                table.add([
                    "\(tone)", order.name, "\(result.looks.count)",
                    histogram.map(String.init).joined(separator: " / "),
                    "\(format(flat.reduce(0, +) / Double(max(1, flat.count)), 1)) / \(format(flat.max() ?? 0, 1))",
                    BenchMode.pair(result.looks.map(\.firstPixels)), BenchMode.pair(result.looks.map(\.keyLook)),
                    BenchMode.pair(result.paths), BenchMode.pair(result.makeKey), BenchMode.pair(result.keyLook),
                    BenchMode.pair(result.toCommit),
                    result.looks.first.map { $0.levels.map { format($0, 0) }.joined(separator: " ") } ?? "-",
                ])
            }
        }
        say(table.render())
        say("longest time on screen in one batch: \(format(longest, 2)) s")
        try? table.render().write(to: out.appendingPathComponent("flash.md"), atomically: true, encoding: .utf8)
        return measured.values.allSatisfy { !$0.looks.isEmpty }
    }

    struct Outcome {
        var measured: Measured
        var onScreen: Double
    }

    /// One batch: the wallpaper goes up, the recorder starts, the panel is summoned `count` times,
    /// everything comes down. Nil when input arrived.
    private static func recordBatch(
        count: Int, scene: DemoScene, canvas: CGRect, wallpaper: CGImage?, clip: URL?
    ) async -> Outcome? {
        let surface = scene.surface
        let summoner = scene.summoner
        let started = Date()
        let backdrop = ShowcaseBackdropWindow(frame: canvas)
        backdrop.show(wallpaper)
        backdrop.orderFrontRegardless()
        backdrop.order(.below, relativeTo: surface.panel.windowNumber)
        defer { backdrop.close() }

        let watch = IdleGuard.Watch()
        var interrupted = false
        watch.onInput = {
            interrupted = true
            summoner.dismiss(returnFocus: true)
        }
        watch.start()
        defer { watch.stop() }

        let region = regionPixels(surface: surface, canvas: canvas)
        let samples = Samples()
        let pixels = ClipRecorder.pixelSize(of: canvas)
        let writer = clip.flatMap {
            try? MP4ClipWriter(
                url: $0, width: pixels.width, height: pixels.height,
                settings: .init(frameRate: nil, bitRate: 24_000_000, keyFrameInterval: 1))
        }
        let recorder = ClipRecorder()
        do {
            try await recorder.start(screenRect: canvas) { frame in
                samples.append(
                    .init(displayTime: frame.displayTime, luminance: meanLuminance(frame.pixels, in: region)))
                writer?.append(frame.pixels, at: frame.time)
            }
        } catch {
            say("flash: could not record: \(error)")
            writer?.cancel()
            return Outcome(measured: Measured(), onScreen: Date().timeIntervalSince(started))
        }
        await pause(ms: 100)
        var measured = Measured()
        var starts: [UInt64] = []
        summoner.probe.onRecord = { record in
            if record.kind == .summon { measured.toCommit.append(record.cpuMilliseconds) }
        }
        defer { summoner.probe.onRecord = nil }
        for _ in 0..<count where !interrupted {
            summoner.takesKeyStatus = true
            starts.append(LatencyClock.now())
            summoner.summon()
            measured.paths.append(summoner.lastTimings.excludingMakeKey)
            measured.makeKey.append(summoner.lastTimings.makeKey)
            measured.keyLook.append(summoner.lastTimings.keyLook)
            await pause(ms: 150)
            summoner.dismiss(returnFocus: true)
            await pause(ms: 120)
        }
        _ = try? await recorder.stop()
        summoner.dismiss(returnFocus: true)
        watch.check()
        let onScreen = Date().timeIntervalSince(started)
        if interrupted || watch.inputArrived {
            writer?.cancel()
            return nil
        }
        if let writer { try? await writer.finish(at: onScreen) }
        measured.looks = SummonLookMeter.analyse(samples.all, starts: starts)
        return Outcome(measured: measured, onScreen: onScreen)
    }

    /// An empty stretch of the query row, in pixels of the canvas from its top-left corner.
    private static func regionPixels(surface: LauncherSurface, canvas: CGRect) -> CGRect {
        let insets = surface.theme.panel.shadowInsets
        let window = surface.panel.frame
        let scale = surface.panel.backingScaleFactor
        let x = window.minX - canvas.minX + insets.left + 420
        let y = canvas.maxY - window.maxY + insets.top + 16
        return CGRect(x: x * scale, y: y * scale, width: 260 * scale, height: 28 * scale)
    }

    /// Mean luminance from 0 to 255 of `region` in a BGRA frame.
    nonisolated private static func meanLuminance(_ pixels: CVPixelBuffer, in region: CGRect) -> Double {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return .nan }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let minX = max(0, Int(region.minX))
        let maxX = min(width, Int(region.maxX))
        let minY = max(0, Int(region.minY))
        let maxY = min(height, Int(region.maxY))
        guard maxX > minX, maxY > minY else { return .nan }
        var sum = 0.0
        for y in minY..<maxY {
            let row = bytes + y * rowBytes
            for x in minX..<maxX {
                let pixel = row + x * 4
                sum += 0.0722 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.2126 * Double(pixel[2])
            }
        }
        return sum / Double((maxX - minX) * (maxY - minY))
    }
}
