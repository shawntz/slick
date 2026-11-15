import AppKit
@_spi(Testing) import LauncherUI
import LauncherUITesting

/// Captures every part 2 component in both appearances over the three backdrops and writes one
/// sheet per component: grids, the detail pane, the action and confirm cards, a form, argument
/// chips with the filter chip, the filter menu, the empty state with the loading bar, and the HUD.
/// Prints the contrast of the text each one draws itself.
///
/// `states=a,b` and `backdrops=busy,white` narrow the matrix while iterating on one component.
///
/// Each capture holds key status for about a quarter of a second, and a backdrop stays on screen
/// for at most three captures, well under two seconds.
enum ComponentsMode {
    struct Capture {
        let state: String
        let appearance: String
        let backdrop: BackdropKind
        let image: CGImage
        let contrast: ContrastSample
    }

    static let batchSize = 3

    static func run(_ options: DemoOptions) async -> Bool {
        let out = options.outputDirectory
        let scene = DemoScene()
        let stage = ComponentStage(scene: scene)
        scene.summoner.prewarm()
        let only = options.string("states", "").split(separator: ",").map(String.init)
        let states = ComponentStage.states.filter { only.isEmpty || only.contains($0.name) }
        let backdropNames = options.string("backdrops", "").split(separator: ",").map(String.init)
        let backdrops = BackdropKind.allCases.filter { backdropNames.isEmpty || backdropNames.contains($0.rawValue) }
        var captures: [Capture] = []
        for (name, appearance) in ShotsMode.appearances {
            await CaptureSupport.setAppearance(appearance, scene)
            stage.hud.appearance = NSAppearance(named: appearance)
            for backdrop in backdrops {
                for start in stride(from: 0, to: states.count, by: batchSize) {
                    let batch = states[start..<min(start + batchSize, states.count)]
                    let shot = await CaptureSupport.withBackdrop(backdrop, under: scene) { () async -> [Capture] in
                        var shot: [Capture] = []
                        for state in batch {
                            stage.reset()
                            state.setUp(stage)
                            guard let image = await capture(state, stage: stage) else { continue }
                            let contrast = ComponentContrast.measure(state.name, image: image, stage: stage)
                            shot.append(
                                Capture(
                                    state: state.name, appearance: name, backdrop: backdrop, image: image,
                                    contrast: contrast))
                        }
                        stage.reset()
                        return shot
                    }
                    captures += shot
                    await pause(ms: 600)
                }
            }
        }
        scene.surface.panel.orderOut(nil)

        var table = TextTable(["component", "appearance", "backdrop"] + ContrastSample.headers)
        for capture in captures {
            table.add([capture.state, capture.appearance, capture.backdrop.rawValue] + capture.contrast.cells)
            try? SheetComposer.writePNG(
                capture.image,
                to: out.appendingPathComponent("raw").appendingPathComponent(
                    "\(capture.state)-\(capture.appearance)-\(capture.backdrop.rawValue).png"))
        }
        say("Contrast ratios of text the components draw themselves (titles need 4.5, the rest 3):")
        say(table.render())

        var written: [String] = []
        for state in states {
            let rows = ShotsMode.appearances.map { appearance in
                backdrops.compactMap { backdrop -> SheetComposer.Cell? in
                    guard
                        let capture = captures.first(where: {
                            $0.state == state.name && $0.appearance == appearance.name && $0.backdrop == backdrop
                        })
                    else { return nil }
                    let verdict = capture.contrast.passes ? "pass" : "FAIL"
                    return .init(
                        image: capture.image, caption: "\(appearance.name) over \(backdrop.rawValue): \(verdict)")
                }
            }
            if let sheet = SheetComposer.compose(
                title: state.caption.prefix(1).uppercased() + state.caption.dropFirst(), rows: rows)
            {
                let file = "sheet-\(state.name).png"
                try? SheetComposer.writePNG(sheet, to: out.appendingPathComponent(file))
                written.append(file)
            }
        }
        say("wrote \(written.joined(separator: ", ")) and \(captures.count) captures under raw/ in \(out.path)")
        let expected = states.count * ShotsMode.appearances.count * backdrops.count
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
