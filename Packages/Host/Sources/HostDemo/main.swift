// HostDemo: capture sheets and in-app latency numbers for the real panel over fake root search, run
// as an LSUIElement app through LaunchServices.
//
//   HostDemo shots out=<dir> [dark=1]   root, action panel, toast, confirm card and a pushed list
//   HostDemo pages out=<dir> [dark=1]   grid, list with detail, streaming detail, form error, Quick Look,
//                                       filter dropdown and notice banner
//   HostDemo bench [only=grid,push]     the host's latency tables through HostBench, as an app
//   HostDemo scenario file=<json>       a scenario against the demo world, captures in out
//
// Every mode ends with a "<mode> PASS" or "<mode> FAIL" line, and a watchdog ends the process if
// a mode hangs. The panel stays in the bottom-left corner and holds key status only while a
// capture needs the key look.
import AppKit
import Host
import LauncherUI

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let arguments = Array(CommandLine.arguments.dropFirst())
let mode = arguments.first ?? "shots"
var options: [String: String] = [:]
for argument in arguments.dropFirst() {
    let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
    if parts.count == 2 { options[parts[0]] = parts[1] }
}
let watchdog = options["watchdog"].flatMap(Double.init) ?? 120

DispatchQueue.main.asyncAfter(deadline: .now() + watchdog) {
    say("watchdog: \(mode) did not finish within \(Int(watchdog)) s")
    exit(3)
}

Task { @MainActor in
    NSApp.deactivate()
    GlassPanel.installEditMenu()
    await pause(ms: 150)
    let out = URL(fileURLWithPath: options["out"] ?? FileManager.default.currentDirectoryPath, isDirectory: true)
    let passed: Bool
    switch mode {
    case "shots": passed = await ShotsMode.run(out: out, dark: options["dark"] == "1")
    case "pages": passed = await PagesMode.run(out: out, dark: options["dark"] == "1")
    case "bench": passed = await BenchMode.run(only: options["only"])
    case "scenario": passed = await ScenarioMode.run(file: options["file"], out: out)
    default:
        say("unknown mode \(mode); use shots, pages, bench or scenario")
        passed = false
    }
    say("\(mode) \(passed ? "PASS" : "FAIL")")
    exit(passed ? 0 : 1)
}

application.run()
