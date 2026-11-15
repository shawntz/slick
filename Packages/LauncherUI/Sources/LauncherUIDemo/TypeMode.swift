import AppKit
import LauncherUI
import LauncherUITesting

/// Types queries into the panel through `window.sendEvent`, which reaches a panel that is not
/// key, so nothing takes focus and nothing is posted to the system. Each keystroke runs the real
/// path: field editor, text change, filtering, list update, ghost completion and action bar.
/// Selection moves go through the field editor's commands, as the arrow keys would.
///
/// Measures, per keystroke, the main thread's CPU from dispatch to the probe's record, and the
/// probe's own handler-to-commit and handler-to-frame times, and prints them against the
/// keystroke budget in docs/ARCHITECTURE.md. Passes when the text typed is the text shown and
/// every keystroke produced a complete record.
enum TypeMode {
    static let queries = ["aurora", "cobalt term", "clip hist", "window left", "convert", "search emo"]

    /// `animate=0` snaps the glass height instead of animating it; `fill=<rows>` pads results so
    /// the height stays the same, as with a large catalog. Both separate the cost of resizing.
    static func run(_ options: DemoOptions) async -> Bool {
        var theme = Theme.standard
        if options.int("animate", 1) == 0 { theme.motion.heightChange = 0 }
        let scene = DemoScene(theme: theme)
        scene.minimumRows = options.int("fill", 0)
        scene.summoner.prewarm()
        scene.summoner.takesKeyStatus = false
        let panel = scene.surface.panel
        var records: [LatencyProbe.Record] = []
        let waiter = RecordWaiter()
        scene.summoner.probe.onRecord = {
            records.append($0)
            waiter.resume()
        }
        var totals: [Double] = []
        var mismatches: [String] = []
        var seed: UInt64 = 7
        for query in queries {
            scene.summoner.summon()
            await pause(ms: 60)
            for character in query {
                guard let event = SyntheticEvents.key(character, in: panel) else { continue }
                totals.append(await send(event, to: panel, waiter: waiter))
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                await pause(ms: 40 + Double(seed >> 59))
            }
            if scene.surface.queryField.text != query {
                mismatches.append("typed \(query), shown \(scene.surface.queryField.text)")
            }
            // Arrow keys sent to a panel that is not key make the running app's text input
            // system fail before the field sees them; real arrows only reach the key window.
            // Navigation therefore goes through the field editor's command path.
            for down in [true, true, false] {
                panel.queryFieldEditor.doCommand(
                    by: down ? #selector(NSResponder.moveDown(_:)) : #selector(NSResponder.moveUp(_:)))
                await pause(ms: 40)
            }
            for _ in query {
                if let event = SyntheticEvents.delete(in: panel) { _ = await send(event, to: panel, waiter: waiter) }
                await pause(ms: 15)
            }
            scene.summoner.dismiss(returnFocus: false)
            await pause(ms: 500)
        }
        panel.orderOut(nil)

        let keystrokes = records.filter { $0.kind == .keystroke && $0.isComplete }
        let selections = records.filter { $0.kind == .selection && $0.isComplete }
        let total = LatencySummary(totals)
        var table = TextTable(["measure (ms)", "n", "min", "p50", "p90", "p99"])
        func add(_ name: String, _ summary: LatencySummary) {
            table.add([
                name, "\(summary.count)", format(summary.min), format(summary.p50), format(summary.p90),
                format(summary.p99),
            ])
        }
        add("keystroke main-thread CPU, dispatch to record", total)
        add("keystroke CPU, handler to commit (probe)", LatencySummary(keystrokes.map(\.cpuMilliseconds)))
        add("keystroke handler to commit", LatencySummary(keystrokes.map(\.handlerToCommit)))
        add("keystroke handler to frame target", LatencySummary(keystrokes.map(\.handlerToFrameTarget)))
        add("selection move CPU (probe)", LatencySummary(selections.map(\.cpuMilliseconds)))
        say(table.render())
        for mismatch in mismatches { say("mismatch: \(mismatch)") }
        let withinBudget = total.p99 <= 5 && total.p50 <= 3
        say(
            String(
                format: "keystroke budget (3 ms p50, 5 ms p99 of main-thread work): p50 %.2f, p99 %.2f: %@", total.p50,
                total.p99,
                withinBudget ? "within" : "over"))
        let expected = queries.reduce(0) { $0 + 2 * $1.count }
        say("complete keystroke records: \(keystrokes.count) of \(expected)")
        return mismatches.isEmpty && keystrokes.count == expected
    }

    /// Sends one key event and waits for the probe's record. Returns the main thread's CPU time
    /// from dispatch to the record: the field editor, the host's handler, drawing and commit.
    private static func send(_ event: NSEvent, to panel: NSWindow, waiter: RecordWaiter) async -> Double {
        let start = LatencyClock.threadCPUNanoseconds()
        panel.sendEvent(event)
        await waiter.wait(timeout: 0.1)
        return Double(LatencyClock.threadCPUNanoseconds() - start) / 1e6
    }
}
