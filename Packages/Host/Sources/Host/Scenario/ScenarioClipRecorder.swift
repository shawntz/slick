#if SCENARIO_RECORDING
    import AppKit
    import Foundation
    import ImageIO
    import LauncherUI
    import LauncherUITesting
    import UniformTypeIdentifiers

    /// Takes the clips for `record` steps with LauncherUITesting's recorder and encoders.
    ///
    /// Only builds made with `SCENARIO_RECORDING=1` compile it, so the release app links neither
    /// LauncherUITesting nor the video frameworks. The steps are in docs/SCENARIOS.md.
    ///
    /// A clip holds key status for its whole length, so the glass shows its full look. It starts
    /// only after the Mac has been idle for the time the step asks, and the moment a person touches
    /// the keyboard or mouse it puts the panel away, gives key status back and throws the clip out.
    ///
    /// The recorded area is ``ScenarioRecording/canvasSize`` in the bottom-left corner of the main
    /// screen, with the glass centred across it and 6 points above its middle, as in the published
    /// stills. The wallpaper behind it is the stills' own, from `ShowcaseArt`.
    @MainActor public final class ScenarioClipRecorder: ScenarioRecorder {
        /// How far above the canvas's middle the glass sits, as in the stills.
        static let lift: CGFloat = 6

        public private(set) var inputArrived = false
        private var session: Session?

        public init() {}

        /// One clip in progress and what to put back after it.
        private final class Session {
            let recording: ScenarioRecording
            let panel: PanelController
            let folder: URL
            let master: URL
            let canvas: CGRect
            let placedOrigin: CGPoint
            let restoreOrigin: CGPoint
            let restoreAppearance: NSAppearance?
            let backdrop: NSWindow?
            let watch: IdleGuard.Watch
            let capture: ClipRecorder
            let writer: MP4ClipWriter
            let frames: FrameLog
            let idleAtStart: Double
            var moveObserver: (any NSObjectProtocol)?
            var unkeyedSteps: [String] = []

            init(
                recording: ScenarioRecording, panel: PanelController, folder: URL, master: URL, canvas: CGRect,
                placedOrigin: CGPoint, restoreOrigin: CGPoint, restoreAppearance: NSAppearance?, backdrop: NSWindow?,
                watch: IdleGuard.Watch, capture: ClipRecorder, writer: MP4ClipWriter, frames: FrameLog,
                idleAtStart: Double
            ) {
                self.recording = recording
                self.panel = panel
                self.folder = folder
                self.master = master
                self.canvas = canvas
                self.placedOrigin = placedOrigin
                self.restoreOrigin = restoreOrigin
                self.restoreAppearance = restoreAppearance
                self.backdrop = backdrop
                self.watch = watch
                self.capture = capture
                self.writer = writer
                self.frames = frames
                self.idleAtStart = idleAtStart
            }
        }

        // MARK: Starting

        public func start(_ recording: ScenarioRecording, panel: PanelController, folder: URL) async -> String? {
            guard session == nil else { return "a clip is already recording" }
            inputArrived = false
            guard let idle = IdleGuard.idleSeconds() else { return "the Mac's idle time cannot be read" }
            guard idle >= recording.idle else {
                return "the Mac was idle for \(Int(idle)) s and this clip needs \(Int(recording.idle)) s"
            }
            guard let screen = NSScreen.main else { return "there is no screen" }
            let surface = panel.surface
            let window = surface.panel
            let visible = screen.visibleFrame
            let canvas = CGRect(
                origin: CGPoint(x: visible.minX.rounded(), y: visible.minY.rounded()),
                size: ScenarioRecording.canvasSize)
            let restoreOrigin = window.frame.origin
            let restoreAppearance = window.appearance
            if let appearance = recording.appearance {
                let look = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
                NSApp.appearance = look
                window.appearance = look
                surface.refreshTheme()
            }
            let placedOrigin = Self.origin(for: surface, in: canvas)
            surface.place(windowOrigin: placedOrigin)

            var backdrop: ShowcaseBackdropWindow?
            if recording.backdrop == .wallpaper {
                let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let scale = screen.backingScaleFactor
                let picture = ShowcaseArt.render(
                    dark ? ShowcaseArt.darkWallpaper : ShowcaseArt.lightWallpaper,
                    pixels: CGSize(width: canvas.width * scale, height: canvas.height * scale))
                let made = ShowcaseBackdropWindow(frame: canvas)
                made.show(picture)
                made.orderFrontRegardless()
                made.order(.below, relativeTo: window.windowNumber)
                backdrop = made
            }

            // The glass finishes taking a new look only after a moment on screen, so show the panel
            // once without key status before the clip starts.
            let summoner = panel.summoner
            if panel.isPanelVisible {
                // The field's placeholder takes its key look a little after the glass does.
                summoner.takesKeyStatus = true
                window.makeKey()
                try? await Task.sleep(for: .milliseconds(700))
            } else {
                summoner.takesKeyStatus = false
                panel.summon()
                try? await Task.sleep(for: .milliseconds(500))
                panel.dismiss()
                summoner.takesKeyStatus = true
                try? await Task.sleep(for: .milliseconds(150))
            }

            let watch = IdleGuard.Watch()
            let pixels = ClipRecorder.pixelSize(of: canvas)
            let master = folder.appending(path: "\(recording.name)-master.mp4")
            let writer: MP4ClipWriter
            do {
                writer = try MP4ClipWriter(
                    url: master, width: pixels.width, height: pixels.height,
                    settings: .init(frameRate: nil, bitRate: 24_000_000, keyFrameInterval: 1))
            } catch {
                putBack(window: window, panel: panel, origin: restoreOrigin, appearance: restoreAppearance)
                backdrop?.close()
                return "cannot open \(master.lastPathComponent): \(error)"
            }
            let frames = FrameLog()
            let capture = ClipRecorder(frameRate: recording.frameRate)
            let session = Session(
                recording: recording, panel: panel, folder: folder, master: master, canvas: canvas,
                placedOrigin: placedOrigin, restoreOrigin: restoreOrigin, restoreAppearance: restoreAppearance,
                backdrop: backdrop, watch: watch, capture: capture, writer: writer, frames: frames, idleAtStart: idle)
            watch.onInput = { [weak self] in self?.inputDidArrive() }
            watch.start()
            self.session = session
            // A theme with other metrics moves the window back to its usual place; keep it here.
            session.moveObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.keepPlaced() }
            }
            do {
                try await capture.start(screenRect: canvas) { frame in
                    frames.add(kept: writer.append(frame.pixels, at: frame.time), at: frame.time)
                }
            } catch {
                await cancel()
                return "cannot start recording: \(error)"
            }
            return inputArrived ? "input arrived as the clip started, so it was thrown out" : nil
        }

        /// The window origin that puts the glass where the stills have it in `canvas`.
        static func origin(for surface: LauncherSurface, in canvas: CGRect) -> CGPoint {
            let glass = surface.geometry.glassFrame
            let height = surface.targetGlassHeight > 1 ? surface.targetGlassHeight : glass.height
            let glassLeft = canvas.minX + ((canvas.width - glass.width) / 2).rounded()
            let glassTop = canvas.maxY - (((canvas.height - height) / 2).rounded() - lift)
            return CGPoint(x: glassLeft - glass.minX, y: glassTop + glass.minY - surface.panel.frame.height)
        }

        // MARK: During the clip

        /// Moves the window back into the canvas when something else moved it.
        private func keepPlaced() {
            guard let session else { return }
            let surface = session.panel.surface
            guard surface.panel.frame.origin != session.placedOrigin else { return }
            surface.place(windowOrigin: session.placedOrigin)
        }

        public func stepDidRun(_ step: ScenarioStep) {
            guard let session, session.panel.isPanelVisible, !session.panel.surface.panel.isKeyWindow else { return }
            session.unkeyedSteps.append(step.name)
        }

        /// A person touched the Mac: put everything away at once. The runner stops at its next check.
        private func inputDidArrive() {
            inputArrived = true
            guard let session else { return }
            session.panel.summoner.takesKeyStatus = false
            session.panel.dismiss()
            session.backdrop?.orderOut(nil)
        }

        // MARK: Ending

        public func stop(_ output: ScenarioClipOutput) async -> Result<[String], ScenarioRecorderFailure> {
            guard let session else { return .failure(.init("no clip is recording")) }
            self.session = nil
            session.watch.stop()
            let summary = try? await session.capture.stop()
            let end = session.frames.elapsed
            finish(session)
            if inputArrived || session.watch.inputArrived {
                inputArrived = true
                session.writer.cancel()
                return .failure(.init("input arrived during the clip, so it was thrown out"))
            }
            guard let summary, summary.frames > 0 else {
                session.writer.cancel()
                return .failure(.init("no frames arrived"))
            }
            do {
                try await session.writer.finish(at: end)
            } catch {
                return .failure(.init("cannot finish \(session.master.lastPathComponent): \(error)"))
            }
            guard session.unkeyedSteps.isEmpty else {
                return .failure(
                    .init(
                        "the panel showed without key status after \(session.unkeyedSteps), so the glass looked flat; "
                            + "the master is kept for a look"))
            }
            let name = session.recording.name
            let log = session.frames.snapshot
            var report = ClipReport(
                name: name, appearance: session.recording.appearance?.rawValue, seconds: end, frames: summary.frames,
                frameRate: summary.frameRate, width: summary.width, height: summary.height,
                firstFrameAfter: log.firstFrameAfter, largestGap: log.largestGap, framesNotKept: log.notKept,
                idleAtStart: session.idleAtStart, files: [:])
            do {
                let encoded = try await ClipEncoding.encode(
                    master: session.master, name: name, folder: session.folder, output: output)
                report.files = encoded.files
                let sheets = [
                    ("\(name)-sheet.png", "\(name): \(String(format: "%.2f", end)) s", encoded.overview, 4),
                    ("\(name)-start.png", "\(name): the first frames", encoded.start, 6),
                ]
                var written = encoded.files.values.map { session.folder.appending(path: $0.file).path }
                for (file, title, cells, columns) in sheets where !cells.isEmpty {
                    let rows = stride(from: 0, to: cells.count, by: columns).map {
                        Array(cells[$0..<min($0 + columns, cells.count)])
                    }
                    guard let sheet = SheetComposer.compose(title: title, rows: rows, scale: 1) else { continue }
                    let url = session.folder.appending(path: file)
                    try SheetComposer.writePNG(sheet, to: url)
                    written.append(url.path)
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let reportURL = session.folder.appending(path: "\(name).json")
                try encoder.encode(report).write(to: reportURL, options: .atomic)
                written.append(reportURL.path)
                return .success(written.sorted())
            } catch let failure as ScenarioRecorderFailure {
                return .failure(failure)
            } catch {
                return .failure(.init("cannot make the copies of \(name): \(error)"))
            }
        }

        public func cancel() async {
            guard let session else { return }
            self.session = nil
            session.watch.stop()
            _ = try? await session.capture.stop()
            finish(session)
            session.writer.cancel()
        }

        /// Puts the panel back where the run had it, without key status, and closes the wallpaper.
        private func finish(_ session: Session) {
            if let observer = session.moveObserver { NotificationCenter.default.removeObserver(observer) }
            session.moveObserver = nil
            putBack(
                window: session.panel.surface.panel, panel: session.panel, origin: session.restoreOrigin,
                appearance: session.restoreAppearance)
            session.backdrop?.close()
        }

        private func putBack(window: GlassPanel, panel: PanelController, origin: CGPoint, appearance: NSAppearance?) {
            panel.summoner.takesKeyStatus = false
            if window.isKeyWindow {
                // Giving key status back must not dismiss the panel.
                let handler = window.onResignKey
                window.onResignKey = nil
                NSApp.deactivate()
                window.resignKey()
                window.onResignKey = handler
            }
            if window.appearance != appearance {
                NSApp.appearance = nil
                window.appearance = appearance
                panel.surface.refreshTheme()
            }
            panel.surface.place(windowOrigin: origin)
        }
    }

    /// When each frame came and whether the writer kept it. Written from the recorder's queue.
    nonisolated final class FrameLog: @unchecked Sendable {
        private let lock = NSLock()
        private let started = Date()
        private var firstFrame: Date?
        private var times: [Double] = []
        private var notKept = 0

        func add(kept: Bool, at time: Double) {
            lock.withLock {
                if firstFrame == nil { firstFrame = Date() }
                times.append(time)
                if !kept { notKept += 1 }
            }
        }

        /// Seconds since the first frame.
        var elapsed: Double { lock.withLock { firstFrame.map { Date().timeIntervalSince($0) } ?? 0 } }

        var snapshot: (firstFrameAfter: Double, largestGap: Double, notKept: Int) {
            lock.withLock {
                let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
                return (firstFrame.map { $0.timeIntervalSince(started) } ?? 0, gaps.max() ?? 0, notKept)
            }
        }
    }

    /// What a clip became, written beside it as `<name>.json`.
    nonisolated struct ClipReport: Encodable, Sendable {
        struct File: Encodable, Sendable {
            var file: String
            var bytes: Int
            var width: Int
            var height: Int
            var frameRate: Double?
            var bitRate: Int?
            var colors: Int?
            var frames: Int?
            var seconds: Double?
        }

        var name: String
        var appearance: String?
        var seconds: Double
        var frames: Int
        var frameRate: Double
        var width: Int
        var height: Int
        /// Seconds from the recorder's start to its first frame.
        var firstFrameAfter: Double
        /// The longest time without a new frame. The window server sends none while nothing moves.
        var largestGap: Double
        /// Frames the master's writer did not take because its encoder was busy.
        var framesNotKept: Int
        var idleAtStart: Double
        var files: [String: File]
    }

    /// Makes the published copies of a master clip, off the main thread.
    nonisolated enum ClipEncoding {
        struct Encoded: Sendable {
            var files: [String: ClipReport.File]
            var overview: [SheetComposer.Cell]
            var start: [SheetComposer.Cell]
        }

        /// Tries each setting in turn until the copy fits its budget.
        static let webLadder: [(frameRate: Double, scale: Double, bitRate: Int)] = [
            (60, 1, 8_000_000), (60, 1, 5_000_000), (30, 1, 4_000_000), (30, 1, 2_500_000), (30, 0.75, 2_500_000),
            (30, 0.5, 2_000_000),
        ]
        static let gifLadder: [(frameRate: Double, colors: Int)] = [(20, 256), (15, 256), (15, 160), (12, 128)]

        @concurrent static func encode(
            master: URL, name: String, folder: URL, output: ScenarioClipOutput
        ) async throws -> Encoded {
            let info = try await ClipReader.info(of: master)
            var files: [String: ClipReport.File] = [
                "master": .init(
                    file: master.lastPathComponent, bytes: size(of: master), width: info.width, height: info.height,
                    seconds: info.duration)
            ]

            let web = folder.appending(path: "\(name).mp4")
            var webFile: ClipReport.File?
            for step in webLadder {
                let width = Int(Double(info.width) * step.scale) / 2 * 2
                let frames = try await ClipReader.transcode(
                    master, to: web, frameRate: step.frameRate, width: width, bitRate: step.bitRate)
                let bytes = size(of: web)
                let height = Int((Double(info.height) * Double(width) / Double(info.width)).rounded()) / 2 * 2
                webFile = .init(
                    file: web.lastPathComponent, bytes: bytes, width: width, height: height, frameRate: step.frameRate,
                    bitRate: step.bitRate, frames: frames, seconds: info.duration)
                if bytes <= output.webMaxBytes { break }
            }
            guard let webFile, webFile.bytes <= output.webMaxBytes else {
                throw ScenarioRecorderFailure("the web copy is over \(output.webMaxBytes) bytes at every setting")
            }
            files["web"] = webFile

            let gif = folder.appending(path: "\(name).gif")
            var gifFile: ClipReport.File?
            for step in gifLadder {
                let result = try await GIFEncoder.encode(
                    clip: master, to: gif, frameRate: step.frameRate, width: output.gifWidth,
                    settings: .init(colors: step.colors))
                gifFile = .init(
                    file: gif.lastPathComponent, bytes: result.bytes, width: result.width, height: result.height,
                    frameRate: step.frameRate, colors: step.colors, frames: result.frames, seconds: info.duration)
                if result.bytes <= output.gifMaxBytes { break }
            }
            guard let gifFile, gifFile.bytes <= output.gifMaxBytes else {
                throw ScenarioRecorderFailure("the GIF is over \(output.gifMaxBytes) bytes at every setting")
            }
            files["gif"] = gifFile

            // The poster, the overview sheet and the first frames, in one read.
            let posterTime = output.poster ?? .infinity
            let overviewEvery = max(info.duration / 16, 1.0 / 30)
            var poster: ClipFrame?
            var overview: [SheetComposer.Cell] = []
            var start: [SheetComposer.Cell] = []
            var nextOverview = 0.0
            try await ClipReader.read(master, frameRate: 30) { frame in
                if frame.time <= posterTime + 0.0001 { poster = frame }
                let small = { ClipFrame.scaled(frame.image, width: 470) }
                if frame.time >= nextOverview - 0.0001, let image = small() {
                    overview.append(.init(image: image, caption: String(format: "%.2f s", frame.time)))
                    nextOverview += overviewEvery
                }
                if start.count < 18, let image = small() {
                    start.append(.init(image: image, caption: String(format: "%.3f s", frame.time)))
                }
            }
            guard let poster else { throw ScenarioRecorderFailure("the clip has no frame for the poster") }
            let posterURL = folder.appending(path: "\(name)-poster.png")
            try writePNG(poster.image, to: posterURL)
            files["poster"] = .init(
                file: posterURL.lastPathComponent, bytes: size(of: posterURL), width: poster.image.width,
                height: poster.image.height, seconds: poster.time)
            return Encoded(files: files, overview: overview, start: start)
        }

        static func size(of url: URL) -> Int {
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        }

        static func writePNG(_ image: CGImage, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard
                let destination = CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { throw ScenarioRecorderFailure("cannot write \(url.lastPathComponent)") }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw ScenarioRecorderFailure("cannot write \(url.lastPathComponent)")
            }
        }
    }

    extension ClipFrame {
        /// A copy of `image` scaled to `width` pixels wide.
        nonisolated static func scaled(_ image: CGImage, width: Int) -> CGImage? {
            let height = Int((Double(image.height) * Double(width) / Double(image.width)).rounded())
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
    }
#endif
