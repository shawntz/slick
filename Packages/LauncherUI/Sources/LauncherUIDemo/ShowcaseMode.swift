import AppKit
import LauncherUI
import LauncherUITesting

/// Product shots for the website and the README: the real panel, drawn by LauncherUI with the
/// sample catalog, centred on a calm generated wallpaper and captured at the display's scale
/// through ScreenCaptureKit.
///
///   showcase [shots=hero,grid] [tones=dark,light] [marginX=90] [marginY=70] [idle=15]
///   showcase preview=1    the wallpapers, icons and grid pictures alone, with no window
///
/// scripts/ui-showcase.sh runs this mode and turns the captures into the files in site/media.
///
/// Before every batch it waits until nobody has touched the keyboard or mouse for `idle`
/// seconds, and it gives up after `idleBudget` seconds (30 minutes). A batch shows the backdrop
/// and the panel in the bottom-left corner of the main screen for under two seconds, and each
/// capture holds key status for about a quarter of a second. When input arrives during a batch,
/// the batch is thrown away and taken again later.
enum ShowcaseMode {
    enum Tone: String, CaseIterable {
        case dark, light

        var appearance: NSAppearance.Name { self == .dark ? .darkAqua : .aqua }
        var wallpaper: ShowcaseArt.Recipe { self == .dark ? ShowcaseArt.darkWallpaper : ShowcaseArt.lightWallpaper }
    }

    struct Shot {
        let name: String
        var theme: Theme = .standard
        /// Only in dark mode, written without the appearance suffix.
        var darkOnly = false
        /// A synthetic backdrop instead of the wallpaper. Such shots are for comparing, not for
        /// publishing.
        var backdrop: BackdropKind?
        let setUp: @MainActor (ShowcaseStage) -> Void
        var afterSummon: (@MainActor (ShowcaseStage) -> Void)?

        func file(_ tone: Tone) -> String { darkOnly ? "\(name).png" : "\(name)-\(tone.rawValue).png" }
    }

    static let batchSize = 3
    static let settleMilliseconds = 260.0

    static let shots: [Shot] = [
        Shot(name: "hero") { $0.showHero() },
        Shot(name: "suggestions") { $0.showSuggestions() },
        Shot(name: "actions") { $0.showActions() },
        Shot(name: "detail") { $0.showDetail() },
        Shot(name: "grid") { $0.showGrid() },
        Shot(name: "form", setUp: { $0.showForm() }, afterSummon: { $0.moveCaretToEnd() }),
        Shot(name: "theme-standard", theme: .standard, darkOnly: true) { $0.showHero() },
        Shot(name: "theme-graphite", theme: .graphite, darkOnly: true) { $0.showHero() },
        Shot(name: "theme-ocean", theme: .ocean, darkOnly: true) { $0.showHero() },
        Shot(name: "theme-ember", theme: .ember, darkOnly: true) { $0.showHero() },
        Shot(name: "theme-violet", theme: .violet, darkOnly: true) { $0.showHero() },
        // Beam and Clear change the glass itself, so both tones show.
        Shot(name: "theme-beam", theme: .beam) { $0.showSuggestions() },
        Shot(name: "theme-beam-typed", theme: .beam) { $0.showHero() },
        Shot(name: "theme-clear", theme: .clear) { $0.showHero() },
        // Beam at the reference's 520 pt over a light editor window, before anything is typed, to
        // put beside the reference.
        Shot(name: "beam-reference", theme: ShowcaseStage.beamAtReferenceWidth, darkOnly: true, backdrop: .document) {
            $0.showCategories()
        },
    ]

    static func run(_ options: DemoOptions) async -> Bool {
        let out = options.outputDirectory
        let marginX = options.double("marginX", 90)
        let marginY = options.double("marginY", 70)
        let lift = options.double("lift", 6)
        if options.int("preview", 0) == 1 {
            return preview(out, size: canvasSize(marginX: marginX, marginY: marginY, theme: .standard))
        }
        let idleNeeded = options.double("idle", 15)
        let deadline = Date().addingTimeInterval(options.double("idleBudget", 1800))
        let only = Set(options.string("shots", "").split(separator: ",").map(String.init))
        let tones = options.string("tones", "dark,light").split(separator: ",").compactMap {
            Tone(rawValue: String($0))
        }

        guard let screen = NSScreen.main else {
            say("showcase: no screen")
            return false
        }
        let scale = screen.backingScaleFactor
        let size = canvasSize(marginX: marginX, marginY: marginY, theme: .standard)
        // The bottom-left corner of the main screen, away from where people look.
        let canvas = CGRect(origin: CGPoint(x: screen.frame.minX, y: screen.frame.minY), size: size)
        say(
            "showcase: screen \(Int(screen.frame.width))x\(Int(screen.frame.height)) pt at \(format(scale, 0))x; "
                + "canvas \(Int(size.width))x\(Int(size.height)) pt; accent \(describe(NSColor.controlAccentColor))")

        let scene = DemoScene()
        scene.surface.queryField.delegate = nil
        let stage = ShowcaseStage(scene: scene)
        scene.summoner.prewarm()

        var written: [String] = []
        var missing: [String] = []
        for tone in tones {
            let toneShots = shots.filter { (only.isEmpty || only.contains($0.name)) && (!$0.darkOnly || tone == .dark) }
            guard !toneShots.isEmpty else { continue }
            let pixels = CGSize(width: size.width * scale, height: size.height * scale)
            let wallpaper = ShowcaseArt.render(tone.wallpaper, pixels: pixels)
            guard await IdleGate.wait(seconds: idleNeeded, until: deadline) else {
                return finish(written: written, missing: missing + toneShots.map { $0.file(tone) })
            }
            await CaptureSupport.setAppearance(tone.appearance, scene)
            for start in stride(from: 0, to: toneShots.count, by: batchSize) {
                let batch = Array(toneShots[start..<min(start + batchSize, toneShots.count)])
                var images: [(Shot, CGImage)] = []
                for attempt in 1...3 {
                    guard await IdleGate.wait(seconds: idleNeeded, until: deadline) else { break }
                    let started = Date()
                    images = await captureBatch(batch, stage: stage, canvas: canvas, wallpaper: wallpaper, lift: lift)
                    let onScreen = Date().timeIntervalSince(started)
                    let idle = IdleGate.idleSeconds() ?? 0
                    say("showcase: \(tone.rawValue) batch \(batch.map(\.name)) on screen \(format(onScreen, 2)) s")
                    if idle < onScreen {
                        say("showcase: input arrived during the batch (attempt \(attempt)); discarding it")
                        images = []
                        await pause(ms: 1000)
                        continue
                    }
                    break
                }
                for shot in batch {
                    guard let image = images.first(where: { $0.0.name == shot.name })?.1 else {
                        missing.append(shot.file(tone))
                        continue
                    }
                    do {
                        try SheetComposer.writePNG(image, to: out.appendingPathComponent(shot.file(tone)))
                        written.append(shot.file(tone))
                    } catch {
                        say("showcase: could not write \(shot.file(tone)): \(error)")
                        missing.append(shot.file(tone))
                    }
                }
                await pause(ms: 600)
            }
        }
        stage.reset()
        scene.surface.theme = .standard
        scene.surface.panel.orderOut(nil)
        return finish(written: written, missing: missing)
    }

    private static func finish(written: [String], missing: [String]) -> Bool {
        say("showcase: wrote \(written.count): \(written.joined(separator: ", "))")
        if !missing.isEmpty { say("showcase: missing \(missing.count): \(missing.joined(separator: ", "))") }
        return missing.isEmpty && !written.isEmpty
    }

    /// The panel's widest glass plus margins on every side.
    static func canvasSize(marginX: Double, marginY: Double, theme: Theme) -> CGSize {
        CGSize(width: theme.panel.width + 2 * marginX, height: theme.maxGlassHeight + 2 * marginY)
    }

    /// Shows the backdrop, captures each shot with key status, and closes the backdrop.
    private static func captureBatch(
        _ batch: [Shot], stage: ShowcaseStage, canvas: CGRect, wallpaper: CGImage?, lift: Double
    ) async -> [(Shot, CGImage)] {
        let surface = stage.surface
        let backdrop = ShowcaseBackdropWindow(frame: canvas)
        backdrop.show(wallpaper)
        backdrop.orderFrontRegardless()
        backdrop.order(.below, relativeTo: surface.panel.windowNumber)
        defer { backdrop.close() }
        var images: [(Shot, CGImage)] = []
        for shot in batch {
            let synthetic = shot.backdrop.map { BackdropWindow(kind: $0, frame: canvas) }
            if let synthetic {
                synthetic.orderFrontRegardless()
                synthetic.order(.below, relativeTo: surface.panel.windowNumber)
            }
            defer { synthetic?.close() }
            stage.reset()
            surface.theme = shot.theme
            shot.setUp(stage)
            stage.center(in: canvas, lift: lift)
            let summoner = stage.scene.summoner
            summoner.takesKeyStatus = true
            summoner.summon()
            surface.updateHeight(animated: false)
            shot.afterSummon?(stage)
            await pause(ms: settleMilliseconds)
            let image = try? await OwnWindowCapture.capture(canvas)
            summoner.dismiss(returnFocus: true)
            if let image { images.append((shot, image)) } else { say("showcase: capture of \(shot.name) failed") }
        }
        return images
    }

    private static func describe(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "?" }
        return String(
            format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
            Int(rgb.blueComponent * 255))
    }

    // MARK: Preview without windows

    /// Writes the wallpapers, an icon sheet and the grid pictures, so the art can be checked
    /// without putting anything on screen.
    private static func preview(_ out: URL, size: CGSize) -> Bool {
        let folder = out.appendingPathComponent("preview")
        var ok = true
        for tone in Tone.allCases {
            if let image = ShowcaseArt.render(
                tone.wallpaper, pixels: CGSize(width: size.width * 2, height: size.height * 2))
            {
                ok =
                    ok
                    && (try? SheetComposer.writePNG(image, to: folder.appendingPathComponent("wallpaper-\(tone).png")))
                        != nil
            }
        }
        var icons: [CGImage] = ShowcaseCatalog.heroResults().sections.flatMap { $0.rows.compactMap(\.icon) }
        icons += ShowcaseCatalog.suggestions().sections.flatMap { $0.rows.compactMap(\.icon) }
        icons += ShowcaseCatalog.fileRows().sections.flatMap { $0.rows.compactMap(\.icon) }
        let pictures = ShowcaseCatalog.pictureGrid().sections.flatMap { $0.cells }.compactMap { cell -> CGImage? in
            if case .image(let image) = cell.content { return image }
            return nil
        }
        for (name, images, cell) in [
            ("icons", icons, CGSize(width: 140, height: 140)), ("pictures", pictures, CGSize(width: 340, height: 220)),
        ] {
            if let sheet = strip(images, cell: cell) {
                ok = ok && (try? SheetComposer.writePNG(sheet, to: folder.appendingPathComponent("\(name).png"))) != nil
            }
        }
        say("showcase: preview written to \(folder.path)")
        return ok
    }

    /// Images in rows of eight on a dark band and a light band.
    private static func strip(_ images: [CGImage], cell: CGSize) -> CGImage? {
        let columns = 8
        let rows = (images.count + columns - 1) / columns
        let band = CGFloat(rows) * cell.height
        let width = Int(CGFloat(columns) * cell.width)
        let height = Int(band * 2)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(ShowcaseArt.color(0x1B1B22))
        context.fill(CGRect(x: 0, y: band, width: CGFloat(width), height: band))
        context.setFillColor(ShowcaseArt.color(0xF2F2F6))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: band))
        context.interpolationQuality = .high
        for half in 0..<2 {
            for (index, image) in images.enumerated() {
                let column = index % columns
                let row = index / columns
                let x = CGFloat(column) * cell.width + (cell.width - CGFloat(image.width)) / 2
                let top = CGFloat(height) - CGFloat(half) * band - CGFloat(row) * cell.height
                let y = top - cell.height + (cell.height - CGFloat(image.height)) / 2
                context.draw(image, in: CGRect(x: x, y: y, width: CGFloat(image.width), height: CGFloat(image.height)))
            }
        }
        return context.makeImage()
    }
}

/// The demo scene's panel dressed for each product shot. Every shot starts from `reset()`, so
/// nothing leaks from one shot into the next.
final class ShowcaseStage {
    let scene: DemoScene
    let grid = GridView()
    let split = ListDetailView()
    let form = FormView()
    /// Rendered once, in the panel's colour space, before anything is on screen.
    let pictures: GridContent

    init(scene: DemoScene) {
        self.scene = scene
        pictures = ShowcaseCatalog.pictureGrid()
    }

    var surface: LauncherSurface { scene.surface }

    func reset() {
        surface.dismissOverlay()
        surface.isLoading = false
        surface.queryField.arguments = []
        surface.queryField.filter = nil
        surface.queryField.leading = .root
        surface.queryField.placeholder = "Search apps and commands"
        surface.setContent(scene.list, animated: false)
        surface.queryField.installEditor()
        surface.queryField.text = ""
        surface.queryField.ghostText = ""
        surface.actionBar.show(nil)
    }

    /// Moves the window so the glass sits in the middle of `canvas`, raised by `lift` points so it
    /// looks centred above its own shadow.
    func center(in canvas: CGRect, lift: Double) {
        let theme = surface.theme
        let height = surface.targetGlassHeight
        let insets = theme.panel.shadowInsets
        let glassMinX = (canvas.midX - theme.panel.width / 2).rounded()
        let glassMaxY = (canvas.midY + height / 2 + lift).rounded()
        let windowHeight = surface.panel.frame.height
        surface.place(windowOrigin: CGPoint(x: glassMinX - insets.left, y: glassMaxY + insets.top - windowHeight))
    }

    // MARK: Shots

    /// A typed query: results with match emphasis, the ghost completion and the lens on row one.
    func showHero() {
        surface.queryField.text = ShowcaseCatalog.heroQuery
        surface.queryField.ghostText = ShowcaseCatalog.heroGhost
        scene.list.apply(ShowcaseCatalog.heroResults())
        scene.list.select(0, animated: false)
        surface.actionBar.apply(ActionBarContent(viewTitle: "Search", primaryTitle: "Open Application"))
    }

    func showSuggestions() {
        scene.list.apply(ShowcaseCatalog.suggestions())
        scene.list.select(0, animated: false)
        surface.actionBar.apply(ActionBarContent(viewTitle: "Search", primaryTitle: "Open Application"))
    }

    /// Beam at the reference's width; every other value is Beam's own.
    static let beamAtReferenceWidth: Theme = {
        var theme = Theme.beam
        theme.panel.width = 520
        return theme
    }()

    /// Four rows with white line glyphs and no selection, as the reference shows before anything
    /// is typed. The titles are this app's own words.
    func showCategories() {
        let rows = [
            ("square.grid.2x2", "Apps"), ("folder", "Files"), ("square.stack.3d.up", "Commands"),
            ("doc.on.clipboard", "Clipboard History"),
        ].enumerated().map { index, item in
            ListRow(id: UInt64(index + 1), title: item.1, icon: Self.lineGlyph(item.0))
        }
        scene.list.apply(ListContent(sections: [ListSection(rows: rows)]))
        scene.list.select(nil, animated: false)
        surface.actionBar.apply(ActionBarContent(viewTitle: "Search", primaryTitle: "Open"))
    }

    /// A white SF Symbol in a 24 pt box at 2x, as the host draws a symbol icon in dark mode.
    static func lineGlyph(_ name: String) -> CGImage? {
        let pixels = 48
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // The host's recipe for a symbol icon: drawn at 0.7 of the box and fitted, up or down, into
        // the box less 8% on each side.
        let configuration = NSImage.SymbolConfiguration(pointSize: CGFloat(pixels) * 0.7, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let image = symbol.withSymbolConfiguration(configuration) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let size = image.size
        let available = CGFloat(pixels) * 0.84
        let scale = min(available / size.width, available / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        image.draw(
            in: CGRect(
                x: (CGFloat(pixels) - drawn.width) / 2, y: (CGFloat(pixels) - drawn.height) / 2, width: drawn.width,
                height: drawn.height))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    func showActions() {
        showHero()
        let card = ActionCardView(content: ShowcaseCatalog.actions)
        surface.present(card)
        card.selectItem(at: 2)
    }

    func showDetail() {
        surface.queryField.leading = QueryLeading(glyph: .back, breadcrumb: "Search Files")
        surface.queryField.filter = QueryFilter(options: ShowcaseCatalog.fileKinds, selectedID: "all", label: "Kind")
        surface.queryField.text = ShowcaseCatalog.fileQuery
        surface.setContent(split, animated: false)
        split.list.apply(ShowcaseCatalog.fileRows())
        split.list.select(0, animated: false)
        split.detail.apply(
            DetailContent(body: .markdown(ShowcaseCatalog.markdown), metadata: ShowcaseCatalog.metadata))
        surface.actionBar.apply(ActionBarContent(viewTitle: "Search Files", primaryTitle: "Open"))
    }

    func showGrid() {
        surface.queryField.leading = QueryLeading(glyph: .back, breadcrumb: "Pictures")
        surface.queryField.placeholder = "Search pictures"
        surface.setContent(grid, animated: false)
        grid.apply(pictures)
        grid.select(2, animated: false)
        surface.actionBar.apply(ActionBarContent(viewTitle: "Pictures", primaryTitle: "Open"))
    }

    func showForm() {
        surface.queryField.leading = QueryLeading(glyph: .back, breadcrumb: "Create Note")
        surface.queryField.placeholder = ""
        surface.setContent(form, animated: false)
        form.apply(ShowcaseCatalog.noteForm())
        form.focus("title")
        moveCaretToEnd()
        surface.actionBar.apply(
            ActionBarContent(
                viewIcon: ShowcaseCatalog.icon("Aurora Notes"), viewTitle: "Aurora Notes", primaryTitle: "Create Note",
                primaryKeys: ["⌘", "↩"]))
    }

    /// Puts the caret after the focused field's text instead of selecting all of it.
    func moveCaretToEnd() {
        guard let editor = surface.panel.firstResponder as? NSTextView else { return }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }
}
