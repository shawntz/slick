import AppKit
@_spi(Testing) import LauncherUI
import LauncherUITesting

/// One keystroke typed into the query field's editor, split into its parts, as main-thread CPU:
/// the field editor, the scene's update (filter, list apply, selection, action bar), the list's
/// draw, the rest of the panel's draw, and the Core Animation commit. It answers where a keystroke's
/// draw and commit go.
///
/// Each pass types its own queries, so no query is typed twice. Each query is one batch: it waits
/// for 15 s of idle input, shows the panel in the corner without key status, types and deletes the
/// query, and hides the panel, well under two seconds later.
enum KeystrokeBench {
    struct Split {
        var fieldEditor: [Double] = []
        var update: [Double] = []
        var listDraw: [Double] = []
        var otherDraw: [Double] = []
        var commit: [Double] = []
        var drawAndCommit: [Double] = []
        var whole: [Double] = []
        /// The longest time the panel stayed on screen in one batch, in seconds.
        var longestBatch = 0.0
    }

    /// Three sets of six queries over the synthetic catalog, one set per pass.
    static let passes: [[String]] = [
        TypeMode.queries,
        ["basil", "drift brow", "lock scr", "toggle dark", "quill", "timer five"],
        ["harbor", "nimbus fil", "color pick", "paste plain", "sable pod", "kill proc"],
    ]

    /// `lineCache` off types without the list's line cache, for comparison.
    static func run(passes count: Int, lineCache: Bool = true) async -> Split? {
        let scene = DemoScene()
        scene.list.usesLineCache = lineCache
        // Full lists, as a catalog of thousands fills them, so the glass height never changes.
        scene.minimumRows = 9
        scene.summoner.prewarm()
        scene.summoner.takesKeyStatus = false
        let panel = scene.surface.panel
        let editor = panel.queryFieldEditor
        var split = Split()
        for (pass, queries) in passes.prefix(count).enumerated() {
            for (index, query) in queries.enumerated() {
                guard await BenchMode.idle() else { return nil }
                let shown = LatencyClock.now()
                scene.summoner.summon()
                panel.displayIfNeeded()
                CATransaction.flush()
                await pause(ms: 40)
                for character in query {
                    // The very first query warms the caches up and is not counted.
                    measure(scene, into: &split, record: pass > 0 || index > 0) {
                        editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
                    }
                    await pause(ms: 24)
                }
                for _ in query {
                    measure(scene, into: &split, record: true) { editor.deleteBackward(nil) }
                    await pause(ms: 12)
                }
                scene.summoner.dismiss(returnFocus: false)
                panel.displayIfNeeded()
                CATransaction.flush()
                split.longestBatch = max(split.longestBatch, LatencyClock.ms(shown, LatencyClock.now()) / 1000)
                await pause(ms: 200)
            }
        }
        panel.orderOut(nil)
        return split
    }

    private static func measure(_ scene: DemoScene, into split: inout Split, record: Bool, _ type: () -> Void) {
        scene.updateNanoseconds = 0
        let start = LatencyClock.threadCPUNanoseconds()
        type()
        let typed = LatencyClock.threadCPUNanoseconds()
        scene.list.displayIfNeeded()
        let listDrawn = LatencyClock.threadCPUNanoseconds()
        scene.surface.panel.displayIfNeeded()
        let drawn = LatencyClock.threadCPUNanoseconds()
        CATransaction.flush()
        let committed = LatencyClock.threadCPUNanoseconds()
        guard record else { return }
        func ms(_ nanoseconds: UInt64) -> Double { Double(nanoseconds) / 1e6 }
        split.fieldEditor.append(ms(typed - start - scene.updateNanoseconds))
        split.update.append(ms(scene.updateNanoseconds))
        split.listDraw.append(ms(listDrawn - typed))
        split.otherDraw.append(ms(drawn - listDrawn))
        split.commit.append(ms(committed - drawn))
        split.drawAndCommit.append(ms(committed - typed))
        split.whole.append(ms(committed - start))
    }
}
