import AppKit
import LauncherUI
import LauncherUITesting

/// Measures contrast over a sweep of glass tints, to find the least tint that meets glass rule 5
/// over every backdrop in each appearance.
///
/// Options: `light=` and `dark=` list the tint alphas to try; `lightSecondary=` and
/// `darkSecondary=` replace the subtitle, accessory and header colour (a theme colour string);
/// `halo=1` adds a soft opposite-luminance halo behind row text.
enum LegibilityMode {
    static func run(_ options: DemoOptions) async -> Bool {
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
        let sweeps = [
            "light": options.doubles("light", [0, 0.15, 0.3, 0.45]),
            "dark": options.doubles("dark", [0.15, 0.3, 0.45, 0.6]),
        ]
        let scene = DemoScene(theme: theme)
        scene.summoner.prewarm()
        scene.showLegibilityContent()
        var table = TextTable(["appearance", "backdrop", "tint"] + ContrastSample.headers)
        var verdicts: [String: [Double: Bool]] = [:]
        for (name, appearance) in ShotsMode.appearances {
            await CaptureSupport.setAppearance(appearance, scene)
            for backdrop in BackdropKind.allCases {
                let samples = await CaptureSupport.withBackdrop(backdrop, under: scene) {
                    () async -> [(Double, ContrastSample)] in
                    var samples: [(Double, ContrastSample)] = []
                    for tint in sweeps[name] ?? [] {
                        if name == "light" {
                            scene.surface.theme.light.glassTint.alpha = tint
                        } else {
                            scene.surface.theme.dark.glassTint.alpha = tint
                        }
                        scene.showLegibilityContent()
                        guard let image = await CaptureSupport.captureKey(scene) else { continue }
                        samples.append((tint, CaptureSupport.measure(image, scene: scene)))
                        let file = "\(name)-\(backdrop.rawValue)-\(format(tint)).png"
                        try? SheetComposer.writePNG(image, to: options.outputDirectory.appendingPathComponent(file))
                    }
                    return samples
                }
                for (tint, sample) in samples {
                    table.add([name, backdrop.rawValue, format(tint)] + sample.cells)
                    verdicts[name, default: [:]][tint] = (verdicts[name]?[tint] ?? true) && sample.passes
                }
                await pause(ms: 700)
            }
        }
        say(table.render())
        for name in ["light", "dark"] {
            let least = (sweeps[name] ?? []).sorted().first { verdicts[name]?[$0] == true }
            say("\(name): least tint passing over every backdrop: \(least.map { format($0) } ?? "none in the sweep")")
        }
        return true
    }
}
