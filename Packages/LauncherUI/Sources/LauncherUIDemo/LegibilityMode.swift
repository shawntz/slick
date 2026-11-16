import AppKit
import LauncherUI
import LauncherUITesting

/// Measures contrast over a sweep of one setting per theme, to find the least that meets glass
/// rule 5 over every backdrop in each appearance:
/// - Standard: the glass tint's alpha.
/// - Spotlight: the results container's tint alpha.
/// - Glass: the text halo's alpha, with the glass left untinted. Glass's verdicts are expected to
///   fail over a busy backdrop; the numbers go into its description.
///
/// Options: `themes=standard,spotlight,glass` picks the sweeps, all three by default. `light=` and
/// `dark=` list the values to try for every sweep; `lightSecondary=` and `darkSecondary=` replace
/// Standard's subtitle, accessory and header colour (a theme colour string); `halo=1` adds a soft
/// opposite-luminance halo behind Standard's row text. Each backdrop batch waits for `idle`
/// seconds without input first.
enum LegibilityMode {
    /// One setting of one theme, applied to a copy of the theme for an appearance.
    struct Sweep {
        let theme: String
        let setting: String
        let base: Theme
        let values: [String: [Double]]
        let apply: (inout Theme, _ dark: Bool, _ value: Double) -> Void
    }

    static func run(_ options: DemoOptions) async -> Bool {
        let names = options.string("themes", ShotsMode.defaultThemes).split(separator: ",")
            .map { ThemeStore.currentName(for: String($0)).lowercased() }
        let sweeps = names.compactMap { sweep($0, options) }
        guard sweeps.count == names.count else {
            say("legibility: themes are standard, spotlight and glass")
            return false
        }
        let idle = options.double("idle", 15)
        let deadline = Date().addingTimeInterval(options.double("idleBudget", 1800))
        let scene = DemoScene()
        scene.summoner.prewarm()
        var table = TextTable(["theme", "setting", "appearance", "backdrop", "value"] + ContrastSample.headers)
        for sweep in sweeps {
            scene.surface.theme = sweep.base
            scene.showLegibilityContent()
            var verdicts: [String: [Double: Bool]] = [:]
            for (name, appearance) in ShotsMode.appearances {
                guard await IdleGate.wait(seconds: idle, until: deadline) else { return false }
                await CaptureSupport.setAppearance(appearance, scene)
                let dark = name == "dark"
                for backdrop in BackdropKind.matrix {
                    guard await IdleGate.wait(seconds: idle, until: deadline) else { return false }
                    let samples = await CaptureSupport.withBackdrop(backdrop, under: scene) {
                        () async -> [(Double, ContrastSample)] in
                        var samples: [(Double, ContrastSample)] = []
                        for value in sweep.values[name] ?? [] {
                            var theme = sweep.base
                            sweep.apply(&theme, dark, value)
                            scene.surface.theme = theme
                            scene.showLegibilityContent()
                            guard let image = await CaptureSupport.captureKey(scene) else { continue }
                            samples.append((value, CaptureSupport.measure(image, scene: scene)))
                            let file = "\(sweep.theme)-\(name)-\(backdrop.rawValue)-\(format(value)).png"
                            try? SheetComposer.writePNG(image, to: options.outputDirectory.appendingPathComponent(file))
                        }
                        return samples
                    }
                    for (value, sample) in samples {
                        table.add([sweep.theme, sweep.setting, name, backdrop.rawValue, format(value)] + sample.cells)
                        verdicts[name, default: [:]][value] = (verdicts[name]?[value] ?? true) && sample.passes
                    }
                    await pause(ms: 700)
                }
            }
            for name in ["light", "dark"] {
                let least = (sweep.values[name] ?? []).sorted().first { verdicts[name]?[$0] == true }
                say(
                    "\(sweep.theme) \(name): least \(sweep.setting) passing over every backdrop: "
                        + (least.map { format($0) } ?? "none in the sweep"))
            }
        }
        scene.surface.theme = .standard
        say(table.render())
        try? table.render().write(
            to: options.outputDirectory.appendingPathComponent("legibility.md"), atomically: true, encoding: .utf8)
        return true
    }

    private static func sweep(_ name: String, _ options: DemoOptions) -> Sweep? {
        func values(_ light: [Double], _ dark: [Double]) -> [String: [Double]] {
            ["light": options.doubles("light", light), "dark": options.doubles("dark", dark)]
        }
        switch name {
        case "standard":
            return Sweep(
                theme: name, setting: "glass tint", base: standardBase(options),
                values: values([0, 0.15, 0.3, 0.45], [0.15, 0.3, 0.45, 0.6])
            ) { theme, dark, value in
                if dark { theme.dark.glassTint.alpha = value } else { theme.light.glassTint.alpha = value }
            }
        case "spotlight":
            return Sweep(
                theme: name, setting: "results tint", base: .spotlight,
                values: values([0.15, 0.3, 0.45], [0.3, 0.4, 0.5])
            ) { theme, dark, value in
                if dark { theme.dark.glassTint.alpha = value } else { theme.light.glassTint.alpha = value }
            }
        case "glass":
            return Sweep(theme: name, setting: "halo", base: .glass, values: values([0, 0.6, 0.95], [0, 0.6, 0.95])) {
                theme, dark, value in
                if dark { theme.dark.textHalo?.alpha = value } else { theme.light.textHalo?.alpha = value }
            }
        default:
            return nil
        }
    }

    /// Standard with the colour options applied.
    private static func standardBase(_ options: DemoOptions) -> Theme {
        var theme = Theme.standard
        if let color = ThemeColor(options.string("lightSecondary", "")) {
            (theme.light.subtitle, theme.light.accessory, theme.light.sectionHeader, theme.light.keycapText) = (
                color, color, color, color
            )
        }
        if let color = ThemeColor(options.string("darkSecondary", "")) {
            (theme.dark.subtitle, theme.dark.accessory, theme.dark.sectionHeader, theme.dark.keycapText) = (
                color, color, color, color
            )
        }
        theme.light.tagTextDepth = options.double("lightTagDepth", theme.light.tagTextDepth)
        theme.dark.tagTextDepth = options.double("darkTagDepth", theme.dark.tagTextDepth)
        if options.int("halo", 0) == 1 {
            theme.light.textHalo = ThemeColor(.white, alpha: 0.7)
            theme.dark.textHalo = ThemeColor(.black, alpha: 0.7)
        }
        return theme
    }
}
