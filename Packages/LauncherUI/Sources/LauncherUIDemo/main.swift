// LauncherUIDemo: captures, benchmarks and synthetic typing for LauncherUI, run as an app.
//
//   scripts/ui-demo.sh shots   [out=<dir>]      the capture matrix, sheets and contrast table
//   scripts/ui-demo.sh components [states=a,b]  grid, detail, cards, form, chips, empty state, HUD
//   scripts/ui-demo.sh legibility [out=<dir>]   contrast over a sweep of glass tints
//   scripts/ui-demo.sh vibrancy                 whether template images get vibrancy in glass
//   scripts/ui-demo.sh bench                    latency tables and budget verdicts
//   scripts/ui-demo.sh type                     synthetic typing through window.sendEvent
//   scripts/ui-demo.sh accessibility            the panel read through the AXUIElement API
//   scripts/ui-showcase.sh                      product shots for site/media, behind the idle guard
//   scripts/ui-demo.sh record [idle=120]        a short clip in motion, then MP4 and GIF copies
//   scripts/ui-demo.sh noise                    pixel noise in flat areas of the grid, detail and list
//   scripts/ui-demo.sh flash [idle=120]         flat frames before the glass's key look, per summon
//
// It must run as an app launched through LaunchServices: a terminal process gets lower
// scheduling priority and its numbers are not comparable. Every mode ends with a
// "<mode> PASS" or "<mode> FAIL" line, and a watchdog ends the process if a mode hangs.
import AppKit
import LauncherUI

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let options = DemoOptions(Array(CommandLine.arguments.dropFirst()))
let watchdog = options.double("watchdog", 180)

DispatchQueue.main.asyncAfter(deadline: .now() + watchdog) {
    say("watchdog: \(options.mode) did not finish within \(Int(watchdog)) s")
    exit(3)
}

Task { @MainActor in
    // A process started from a terminal begins active; the launcher never is.
    NSApp.deactivate()
    GlassPanel.installEditMenu()
    await pause(ms: 150)
    let passed: Bool
    switch options.mode {
    case "shots": passed = await ShotsMode.run(options)
    case "components": passed = await ComponentsMode.run(options)
    case "legibility": passed = await LegibilityMode.run(options)
    case "vibrancy": passed = await VibrancyMode.run(options)
    case "bench": passed = await BenchMode.run(options)
    case "type": passed = await TypeMode.run(options)
    case "accessibility": passed = await AccessibilityMode.run(options)
    case "showcase": passed = await ShowcaseMode.run(options)
    case "record": passed = await RecordMode.run(options)
    case "noise": passed = await NoiseMode.run(options)
    case "flash": passed = await FlashMode.run(options)
    default:
        say(
            "unknown mode \(options.mode); use shots, components, legibility, vibrancy, bench, type, accessibility, "
                + "showcase, record, noise or flash")
        passed = false
    }
    say("\(options.mode) \(passed ? "PASS" : "FAIL")")
    exit(passed ? 0 : 1)
}

application.run()
