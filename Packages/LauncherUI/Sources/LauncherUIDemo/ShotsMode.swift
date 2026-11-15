import AppKit
@_spi(Testing) import LauncherUI
import LauncherUITesting

/// Writes the capture matrix: backdrops by two appearances, with and without a query, in both
/// lens styles, plus a sheet of other states. Prints the contrast of every capture.
///
///   shots [themes=standard,graphite] [backdrops=busy,white,dark,wallpaper-dark,wallpaper-light]
///         [lenses=both|own] [appearances=light,dark] [extras=1] [idle=15]
///
/// `themes` takes the built-in theme names. `lenses=own` keeps each theme's own lens instead of
/// trying both styles. The wallpaper backdrops are the two generated product-shot wallpapers.
///
/// Every capture holds key status for about a quarter of a second, and a backdrop is on screen
/// for under two seconds per batch. Each batch waits until nobody has touched the keyboard or
/// mouse for `idle` seconds.
enum ShotsMode {
    struct Capture {
        let theme: String
        let appearance: String
        let backdrop: String
        let lens: LensMetrics.Style
        let state: String
        let image: CGImage
        let contrast: ContrastSample
    }

    static let appearances: [(name: String, appearance: NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
    static let query = "co"
    static let syntheticBackdrops = BackdropKind.allCases.map(\.rawValue)
    static let wallpaperBackdrops = ["wallpaper-dark", "wallpaper-light"]
    private static var wallpapers: [String: CGImage?] = [:]

    static func run(_ options: DemoOptions) async -> Bool {
        let out = options.outputDirectory
        let themeNames = options.string("themes", "standard").split(separator: ",").map { $0.lowercased() }
        let themes = themeNames.compactMap { name in
            ThemeStore.builtInThemes.first { $0.name.lowercased() == name }
        }
        guard themes.count == themeNames.count, !themes.isEmpty else {
            say("shots: unknown theme in \(themeNames); built-in themes are \(ThemeStore.builtInThemes.map(\.name))")
            return false
        }
        let backdrops = options.string("backdrops", syntheticBackdrops.joined(separator: ",")).split(separator: ",")
            .map(String.init)
        guard backdrops.allSatisfy({ syntheticBackdrops.contains($0) || wallpaperBackdrops.contains($0) }) else {
            say("shots: backdrops are \((syntheticBackdrops + wallpaperBackdrops).joined(separator: ", "))")
            return false
        }
        let ownLens = options.string("lenses", "both") == "own"
        let appearanceNames = Set(options.string("appearances", "light,dark").split(separator: ",").map(String.init))
        let appearances = Self.appearances.filter { appearanceNames.contains($0.name) }
        let idle = options.double("idle", 15)
        let deadline = Date().addingTimeInterval(options.double("idleBudget", 1800))
        let scene = DemoScene()
        scene.summoner.prewarm()
        var captures: [Capture] = []
        var expected = 0
        for named in themes {
            scene.surface.theme = named.theme
            let lenses = ownLens ? [named.theme.lens.style] : LensMetrics.Style.allCases
            for (name, appearance) in appearances {
                guard await IdleGate.wait(seconds: idle, until: deadline) else { return false }
                await CaptureSupport.setAppearance(appearance, scene)
                for backdrop in backdrops {
                    expected += lenses.count * 2
                    guard await IdleGate.wait(seconds: idle, until: deadline) else { return false }
                    let started = Date()
                    let batch = await withBackdrop(backdrop, under: scene) { () async -> [Capture] in
                        var batch: [Capture] = []
                        for lens in lenses {
                            scene.surface.theme.lens.style = lens
                            for state in ["root", "query"] {
                                if state == "root" { scene.showRoot() } else { scene.show(query: query) }
                                guard let image = await CaptureSupport.captureKey(scene) else { continue }
                                let contrast = CaptureSupport.measure(image, scene: scene)
                                batch.append(
                                    Capture(
                                        theme: named.name, appearance: name, backdrop: backdrop, lens: lens,
                                        state: state, image: image, contrast: contrast))
                            }
                        }
                        return batch
                    }
                    let onScreen = Date().timeIntervalSince(started)
                    if let now = IdleGate.idleSeconds(), now < onScreen {
                        say("shots: input arrived during a batch of \(format(onScreen, 2)) s; the numbers still stand")
                    }
                    captures += batch
                    await pause(ms: 700)
                }
            }
            scene.surface.theme = named.theme
        }
        scene.surface.theme = .standard
        let extras =
            options.int("extras", themes.count == 1 && themes[0].name == ThemeStore.standardName ? 1 : 0) == 1
            ? await extraStates(scene) : []

        var table = TextTable(["theme", "appearance", "backdrop", "lens", "state"] + ContrastSample.headers)
        for capture in captures {
            table.add(
                [capture.theme, capture.appearance, capture.backdrop, capture.lens.rawValue, capture.state]
                    + capture.contrast.cells)
            let prefix = themes.count == 1 && themes[0].name == ThemeStore.standardName ? "" : "\(capture.theme)-"
            let name =
                "\(prefix)\(capture.appearance)-\(capture.backdrop)-\(capture.lens.rawValue)-\(capture.state).png"
            try? SheetComposer.writePNG(
                capture.image, to: out.appendingPathComponent("raw").appendingPathComponent(name))
        }
        say("Contrast ratios (lowest per kind of text; titles need 4.5, the rest 3):")
        say(table.render())
        try? table.render().write(to: out.appendingPathComponent("contrast.md"), atomically: true, encoding: .utf8)

        var written: [String] = []
        for named in themes {
            let prefix = themes.count == 1 && named.name == ThemeStore.standardName ? "" : "\(named.name.lowercased())-"
            for lens in LensMetrics.Style.allCases {
                for state in ["root", "query"] {
                    let rows = appearances.map { appearance in
                        backdrops.compactMap { backdrop -> SheetComposer.Cell? in
                            guard
                                let capture = captures.first(where: {
                                    $0.theme == named.name && $0.appearance == appearance.name
                                        && $0.backdrop == backdrop && $0.lens == lens && $0.state == state
                                })
                            else { return nil }
                            let verdict = capture.contrast.passes ? "pass" : "FAIL"
                            return .init(
                                image: capture.image, caption: "\(appearance.name) over \(backdrop): \(verdict)")
                        }
                    }
                    guard rows.contains(where: { !$0.isEmpty }) else { continue }
                    let title =
                        "\(named.name), \(lens.rawValue) lens, "
                        + (state == "root" ? "empty query (Suggested, Favorites)" : "query \"\(query)\"")
                    if let sheet = SheetComposer.compose(title: title, rows: rows) {
                        let file = "sheet-\(prefix)\(lens.rawValue)-\(state).png"
                        try? SheetComposer.writePNG(sheet, to: out.appendingPathComponent(file))
                        written.append(file)
                    }
                }
            }
        }
        if !extras.isEmpty, let sheet = SheetComposer.compose(title: "Other states", rows: extras) {
            try? SheetComposer.writePNG(sheet, to: out.appendingPathComponent("sheet-extras.png"))
            written.append("sheet-extras.png")
        }
        say("wrote \(written.joined(separator: ", ")) and \(captures.count) captures under raw/ in \(out.path)")
        return captures.count == expected && captures.allSatisfy(\.contrast.passes)
    }

    /// Runs `body` with a synthetic backdrop or a product-shot wallpaper right under the panel.
    static func withBackdrop<T>(_ name: String, under scene: DemoScene, _ body: @MainActor () async -> T) async -> T {
        if let kind = BackdropKind(rawValue: name) {
            return await CaptureSupport.withBackdrop(kind, under: scene, body)
        }
        let tone: ShowcaseMode.Tone = name == "wallpaper-light" ? .light : .dark
        let frame = scene.windowFrame
        let scale = scene.surface.panel.backingScaleFactor
        let pixels = CGSize(width: frame.width * scale, height: frame.height * scale)
        // Rendered once per run, before the window shows.
        let key = "\(name) \(pixels)"
        if wallpapers[key] == nil { wallpapers[key] = ShowcaseArt.render(tone.wallpaper, pixels: pixels) }
        let window = ShowcaseBackdropWindow(frame: frame)
        window.show(wallpapers[key] ?? nil)
        window.orderFrontRegardless()
        window.order(.below, relativeTo: scene.surface.panel.windowNumber)
        defer { window.close() }
        return await body()
    }

    /// Compact mode, two-line rows, a breadcrumb with a toast, and a scrolled list.
    private static func extraStates(_ scene: DemoScene) async -> [[SheetComposer.Cell]] {
        var rows: [[SheetComposer.Cell]] = []
        for (name, appearance) in appearances {
            await CaptureSupport.setAppearance(appearance, scene)
            let backdrop: BackdropKind = name == "light" ? .white : .dark
            let cells = await CaptureSupport.withBackdrop(backdrop, under: scene) { () async -> [SheetComposer.Cell] in
                var cells: [SheetComposer.Cell] = []
                func shoot(_ caption: String) async {
                    if let image = await CaptureSupport.captureKey(scene) {
                        cells.append(.init(image: image, caption: "\(name): \(caption)"))
                    }
                }
                scene.surface.setContent(nil, animated: false)
                scene.surface.queryField.text = ""
                await shoot("compact, before the first keystroke")
                scene.surface.setContent(scene.list, animated: false)

                scene.rowStyle = .twoLine
                scene.show(query: "a")
                await shoot("two-line rows")
                scene.rowStyle = .oneLine

                scene.surface.queryField.leading = QueryLeading(glyph: .back, breadcrumb: "Clipboard History")
                scene.show(query: "e")
                scene.surface.actionBar.show(ActionBarToast(.success, "Copied to clipboard"))
                await pause(ms: 200)
                await shoot("breadcrumb and toast")
                scene.surface.actionBar.show(nil)
                scene.surface.queryField.leading = .root

                scene.show(query: "e")
                scene.list.select(11, animated: false)
                await shoot("scrolled to row 12")
                return cells
            }
            rows.append(cells)
            scene.showRoot()
            await pause(ms: 700)
        }
        return rows
    }
}
