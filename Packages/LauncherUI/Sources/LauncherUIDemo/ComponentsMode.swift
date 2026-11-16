import AppKit
@_spi(Testing) import LauncherUI
import LauncherUITesting

/// Captures every part 2 component in both appearances over the three backdrops and writes one
/// sheet per component: grids, the detail pane, the action and confirm cards, a form, argument
/// chips with the filter chip, the filter menu, the empty state with the loading bar, and the HUD.
/// Prints the contrast of the text each one draws itself.
///
/// `themes=standard,beam,clear` picks the built-in themes, those three by default. `states=a,b` and
/// `backdrops=busy,white` narrow the matrix while iterating on one component.
///
/// Each capture holds key status for about a quarter of a second, and a backdrop stays on screen
/// for at most three captures, well under two seconds. Each batch waits for `idle` seconds without
/// input first.
enum ComponentsMode {
    struct Capture {
        let theme: String
        let state: String
        let appearance: String
        let backdrop: BackdropKind
        let image: CGImage
        let contrast: ContrastSample
    }

    static let batchSize = 3

    static func run(_ options: DemoOptions) async -> Bool {
        let out = options.outputDirectory
        let themeNames = options.string("themes", ShotsMode.defaultThemes).split(separator: ",").map { $0.lowercased() }
        let themes = themeNames.compactMap { name in ThemeStore.builtInThemes.first { $0.name.lowercased() == name } }
        guard themes.count == themeNames.count, !themes.isEmpty else {
            say(
                "components: unknown theme in \(themeNames); built-in themes are \(ThemeStore.builtInThemes.map(\.name))"
            )
            return false
        }
        let idle = options.double("idle", 15)
        let deadline = Date().addingTimeInterval(options.double("idleBudget", 1800))
        let scene = DemoScene()
        let stage = ComponentStage(scene: scene)
        scene.summoner.prewarm()
        let only = options.string("states", "").split(separator: ",").map(String.init)
        let states = ComponentStage.states.filter { only.isEmpty || only.contains($0.name) }
        let backdropNames = options.string("backdrops", "").split(separator: ",").map(String.init)
        let backdrops = BackdropKind.allCases.filter {
            backdropNames.isEmpty ? BackdropKind.matrix.contains($0) : backdropNames.contains($0.rawValue)
        }
        var captures: [Capture] = []
        for named in themes {
            scene.surface.theme = named.theme
            for (name, appearance) in ShotsMode.appearances {
                guard await IdleGate.wait(seconds: idle, until: deadline) else { return false }
                await CaptureSupport.setAppearance(appearance, scene)
                stage.hud.appearance = NSAppearance(named: appearance)
                stage.hud.theme = named.theme
                for backdrop in backdrops {
                    for start in stride(from: 0, to: states.count, by: batchSize) {
                        let batch = states[start..<min(start + batchSize, states.count)]
                        guard await IdleGate.wait(seconds: idle, until: deadline) else { return false }
                        let shot = await CaptureSupport.withBackdrop(backdrop, under: scene) {
                            () async -> [Capture] in
                            var shot: [Capture] = []
                            for state in batch {
                                stage.reset()
                                state.setUp(stage)
                                guard let image = await capture(state, stage: stage) else { continue }
                                let contrast = ComponentContrast.measure(state.name, image: image, stage: stage)
                                shot.append(
                                    Capture(
                                        theme: named.name, state: state.name, appearance: name, backdrop: backdrop,
                                        image: image, contrast: contrast))
                            }
                            stage.reset()
                            return shot
                        }
                        captures += shot
                        await pause(ms: 600)
                    }
                }
            }
        }
        scene.surface.theme = .standard
        scene.surface.panel.orderOut(nil)

        func prefix(_ theme: String) -> String {
            theme == ThemeStore.standardName ? "" : theme.lowercased() + "-"
        }
        var table = TextTable(["theme", "component", "appearance", "backdrop"] + ContrastSample.headers)
        for capture in captures {
            table.add(
                [capture.theme, capture.state, capture.appearance, capture.backdrop.rawValue] + capture.contrast.cells)
            try? SheetComposer.writePNG(
                capture.image,
                to: out.appendingPathComponent("raw").appendingPathComponent(
                    "\(prefix(capture.theme))\(capture.state)-\(capture.appearance)-\(capture.backdrop.rawValue).png"))
        }
        say("Contrast ratios of text the components draw themselves (titles need 4.5, the rest 3):")
        say(table.render())
        try? table.render().write(
            to: out.appendingPathComponent("components-contrast.md"), atomically: true, encoding: .utf8)

        var written: [String] = []
        for named in themes {
            for state in states {
                let rows = ShotsMode.appearances.map { appearance in
                    backdrops.compactMap { backdrop -> SheetComposer.Cell? in
                        guard
                            let capture = captures.first(where: {
                                $0.theme == named.name && $0.state == state.name && $0.appearance == appearance.name
                                    && $0.backdrop == backdrop
                            })
                        else { return nil }
                        let verdict = capture.contrast.passes ? "pass" : "FAIL"
                        return .init(
                            image: capture.image, caption: "\(appearance.name) over \(backdrop.rawValue): \(verdict)")
                    }
                }
                let caption = state.caption.prefix(1).uppercased() + state.caption.dropFirst()
                if let sheet = SheetComposer.compose(title: "\(named.name), \(caption)", rows: rows) {
                    let file = "sheet-\(prefix(named.name))\(state.name).png"
                    try? SheetComposer.writePNG(sheet, to: out.appendingPathComponent(file))
                    written.append(file)
                }
            }
        }
        say("wrote \(written.joined(separator: ", ")) and \(captures.count) captures under raw/ in \(out.path)")
        let expected = themes.count * states.count * ShotsMode.appearances.count * backdrops.count
        return captures.count == expected && captures.allSatisfy(\.contrast.passes)
    }

    /// Captures one state: the panel with key status, or the HUD's window on its own.
    private static func capture(_ state: ComponentStage.State, stage: ComponentStage) async -> CGImage? {
        guard state.usesPanel else {
            await pause(ms: 350)
            let frame = stage.hud.frame.insetBy(dx: -60, dy: -40)
            let image = try? await OwnWindowCapture.capture(frame)
            stage.hud.hide()
            return image
        }
        return await CaptureSupport.captureKey(stage.scene, settle: 260)
    }
}
