import AppKit
import LauncherUI
import LauncherUITesting

/// Records a short clip of the launcher in motion, to prove the recorder: the suggestions, a
/// query typed one letter at a time, the selection moving, and the action panel opening and
/// closing. Then it makes smaller copies, MP4 and GIF at a few settings, and prints their sizes.
///
///   record [idle=120] [idleBudget=1800] [tone=dark] [rate=0] [attempts=3] [encodes=1]
///   record encodes=only    remakes the copies from the last master clip, with no window
///
/// A clip holds key status for its whole length, about six seconds, so it starts only after
/// `idle` seconds without keyboard or mouse input, and the moment input arrives it stops, puts
/// the panel away and throws the clip out. It then waits for idle again, up to `attempts` times.
/// The panel and its wallpaper sit in the bottom-left corner of the main screen. `rate=0`
/// records at the display's refresh rate.
enum RecordMode {
    static let masterName = "record-master.mp4"

    static func run(_ options: DemoOptions) async -> Bool {
        let out = options.outputDirectory
        let master = out.appendingPathComponent(masterName)
        if options.string("encodes", "1") == "only" {
            return await encodeCopies(of: master, into: out)
        }
        let idleNeeded = options.double("idle", 120)
        let deadline = Date().addingTimeInterval(options.double("idleBudget", 1800))
        let tone = ShowcaseMode.Tone(rawValue: options.string("tone", "dark")) ?? .dark
        let rate = options.double("rate", 0)
        guard let screen = NSScreen.main else {
            say("record: no screen")
            return false
        }
        let size = ShowcaseMode.canvasSize(marginX: 90, marginY: 70, theme: .standard)
        let canvas = CGRect(origin: CGPoint(x: screen.frame.minX, y: screen.frame.minY), size: size)
        let scene = DemoScene()
        scene.surface.queryField.delegate = nil
        let stage = ShowcaseStage(scene: scene)
        scene.summoner.prewarm()
        let scale = screen.backingScaleFactor
        let wallpaper = ShowcaseArt.render(
            tone.wallpaper, pixels: CGSize(width: size.width * scale, height: size.height * scale))

        var recorded = false
        for attempt in 1...max(1, options.int("attempts", 3)) {
            guard await IdleGate.wait(seconds: idleNeeded, until: deadline) else { break }
            await CaptureSupport.setAppearance(tone.appearance, scene)
            switch await recordOnce(
                to: master, stage: stage, canvas: canvas, wallpaper: wallpaper, rate: rate > 0 ? rate : nil)
            {
            case .recorded(let summary):
                say(
                    "record: \(summary.frames) frames over \(format(summary.duration, 2)) s at up to "
                        + "\(format(summary.frameRate, 0)) per second, \(summary.width)x\(summary.height) px")
                recorded = true
            case .interrupted:
                say("record: input arrived during attempt \(attempt); the clip was thrown out")
                continue
            case .failed(let reason):
                say("record: \(reason)")
            }
            break
        }
        stage.reset()
        scene.surface.panel.orderOut(nil)
        guard recorded else { return false }
        return options.string("encodes", "1") == "0" ? true : await encodeCopies(of: master, into: out)
    }

    enum Outcome {
        case recorded(ClipRecorder.Summary)
        case interrupted
        case failed(String)
    }

    /// One take: the backdrop and the panel go up, the recorder starts, the storyboard plays and
    /// everything comes down. Input during the take ends it at once.
    private static func recordOnce(
        to master: URL, stage: ShowcaseStage, canvas: CGRect, wallpaper: CGImage?, rate: Double?
    ) async -> Outcome {
        let surface = stage.surface
        let summoner = stage.scene.summoner
        let backdrop = ShowcaseBackdropWindow(frame: canvas)
        backdrop.show(wallpaper)
        stage.reset()
        stage.showSuggestions()
        stage.center(in: canvas, lift: 6)
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

        let pixels = ClipRecorder.pixelSize(of: canvas)
        let writer: MP4ClipWriter
        do {
            writer = try MP4ClipWriter(
                url: master, width: pixels.width, height: pixels.height,
                settings: .init(frameRate: nil, bitRate: 24_000_000, keyFrameInterval: 1))
        } catch {
            return .failed("could not open the master file: \(error)")
        }
        let clock = FirstFrameClock()
        let recorder = ClipRecorder(frameRate: rate)
        summoner.takesKeyStatus = true
        summoner.summon()
        surface.updateHeight(animated: false)
        do {
            try await recorder.start(screenRect: canvas) { frame in
                clock.mark()
                writer.append(frame.pixels, at: frame.time)
            }
        } catch {
            summoner.dismiss(returnFocus: true)
            writer.cancel()
            return .failed("could not start recording: \(error)")
        }

        for step in storyboard(stage) {
            if interrupted { break }
            await pause(ms: step.delay)
            if interrupted { break }
            step.action()
        }
        let summary = try? await recorder.stop()
        summoner.dismiss(returnFocus: true)
        watch.check()
        if interrupted || watch.inputArrived {
            writer.cancel()
            return .interrupted
        }
        do {
            try await writer.finish(at: clock.elapsed)
        } catch {
            return .failed("could not finish the master file: \(error)")
        }
        guard let summary, summary.frames > 0 else { return .failed("no frames arrived") }
        return .recorded(summary)
    }

    /// When the first frame came, so the clip can end as long after it as the take lasted.
    nonisolated final class FirstFrameClock: @unchecked Sendable {
        private let lock = NSLock()
        private var first: Date?

        func mark() { lock.withLock { if first == nil { first = Date() } } }
        var elapsed: Double { lock.withLock { first.map { Date().timeIntervalSince($0) } ?? 0 } }
    }

    struct Step {
        /// Milliseconds to wait before the action.
        let delay: Double
        let action: @MainActor () -> Void
    }

    /// About six seconds: the suggestions, "ca" typed, the selection moving, the action panel.
    static func storyboard(_ stage: ShowcaseStage) -> [Step] {
        let list = stage.scene.list
        let surface = stage.surface
        func type(_ query: String) -> Step {
            Step(delay: 170) {
                surface.queryField.text = query
                surface.queryField.ghostText = ShowcaseCatalog.ghost(for: query)
                list.apply(ShowcaseCatalog.results(for: query))
                list.select(0, animated: false)
                surface.actionBar.apply(ActionBarContent(viewTitle: "Search", primaryTitle: "Open Application"))
            }
        }
        func move(_ delta: Int, after delay: Double) -> Step {
            Step(delay: delay) { _ = list.moveSelection(by: delta, animated: true) }
        }
        var card: ActionCardView?
        return [
            Step(delay: 900) {},
            type("c"), type("ca"),
            Step(delay: 0) { surface.queryField.ghostText = ShowcaseCatalog.ghost(for: "ca") },
            move(1, after: 800), move(1, after: 320), move(-1, after: 320),
            Step(delay: 650) {
                let actions = ActionCardView(content: ShowcaseCatalog.actions)
                card = actions
                surface.present(actions)
            },
            Step(delay: 600) { card?.selectItem(at: 1) },
            Step(delay: 300) { card?.selectItem(at: 2) },
            Step(delay: 900) { surface.dismissOverlay() },
            Step(delay: 900) {},
        ]
    }

    // MARK: Copies

    /// Smaller MP4s and GIFs from the master, with their sizes. Runs with no window.
    static func encodeCopies(of master: URL, into out: URL) async -> Bool {
        guard let info = try? await ClipReader.info(of: master) else {
            say("record: no master clip at \(master.path)")
            return false
        }
        let masterBytes = fileSize(master)
        var table = TextTable(["file", "kind", "rate", "size px", "settings", "frames", "bytes", "KB per s"])
        table.add([
            masterName, "MP4 H.264", "display", "\(info.width)x\(info.height)", "24 Mbit/s, key frame each 1 s", "",
            "\(masterBytes)", format(Double(masterBytes) / 1024 / info.duration, 0),
        ])
        let half = info.width / 2
        let movies: [(name: String, rate: Double, width: Int, bitRate: Int)] = [
            ("clip-60fps-2x-8mbps.mp4", 60, info.width, 8_000_000),
            ("clip-60fps-1x-4mbps.mp4", 60, half, 4_000_000),
            ("clip-30fps-1x-2mbps.mp4", 30, half, 2_000_000),
        ]
        var ok = true
        for movie in movies {
            let url = out.appendingPathComponent(movie.name)
            do {
                let frames = try await ClipReader.transcode(
                    master, to: url, frameRate: movie.rate, width: movie.width, bitRate: movie.bitRate)
                let bytes = fileSize(url)
                let height = info.height * movie.width / info.width
                table.add([
                    movie.name, "MP4 H.264", format(movie.rate, 0), "\(movie.width)x\(height)",
                    "\(movie.bitRate / 1_000_000) Mbit/s", "\(frames)", "\(bytes)",
                    format(Double(bytes) / 1024 / info.duration, 0),
                ])
            } catch {
                say("record: \(movie.name) failed: \(error)")
                ok = false
            }
        }
        let gifs: [(name: String, rate: Double, width: Int, settings: GIFWriter.Settings)] = [
            ("clip-20fps-940w.gif", 20, half, .init()),
            ("clip-20fps-720w.gif", 20, 720, .init()),
            ("clip-15fps-720w.gif", 15, 720, .init()),
            ("clip-12fps-560w.gif", 12, 560, .init()),
            ("clip-20fps-720w-128c.gif", 20, 720, .init(colors: 128)),
            ("clip-20fps-720w-dither.gif", 20, 720, .init(dither: 0.6)),
        ]
        for gif in gifs {
            let url = out.appendingPathComponent(gif.name)
            do {
                let result = try await GIFEncoder.encode(
                    clip: master, to: url, frameRate: gif.rate, width: gif.width, settings: gif.settings)
                let settings =
                    "\(gif.settings.colors) colours"
                    + (gif.settings.dither > 0 ? ", dither \(gif.settings.dither)" : "")
                table.add([
                    gif.name, "GIF", format(gif.rate, 0), "\(result.width)x\(result.height)", settings,
                    "\(result.frames)", "\(result.bytes)", format(Double(result.bytes) / 1024 / info.duration, 0),
                ])
            } catch {
                say("record: \(gif.name) failed: \(error)")
                ok = false
            }
        }
        say("record: copies of a \(format(info.duration, 2)) s clip:")
        say(table.render())
        try? table.render().write(to: out.appendingPathComponent("sizes.md"), atomically: true, encoding: .utf8)
        return ok
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}
