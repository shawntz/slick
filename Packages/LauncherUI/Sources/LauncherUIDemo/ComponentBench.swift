import AppKit
import LauncherUI
import LauncherUITesting

/// Main-thread cost of the part 2 components, measured like the row update: the work, then an
/// explicit display and commit, timed as the main thread's CPU. The panel shows without key status
/// and each batch stays on screen under two seconds.
enum ComponentBench {
    struct Result {
        let label: String
        let cpu: LatencySummary
        let budget: LatencyBudget
        var note = ""
    }

    static let gridQueries = ["amber", "harbor sage", "tide", "zephyr", "quartz moss", "lumen"]

    /// A scene showing `content`, summoned without key status in the corner.
    private static func makeScene(_ content: any LauncherContentView) -> DemoScene {
        let scene = DemoScene()
        scene.summoner.prewarm()
        scene.summoner.takesKeyStatus = false
        scene.surface.setContent(content, animated: false)
        scene.surface.updateHeight(animated: false)
        scene.summoner.summon()
        return scene
    }

    private static func finish(_ scene: DemoScene) async {
        scene.summoner.dismiss(returnFocus: false)
        scene.surface.panel.orderOut(nil)
        await pause(ms: 400)
    }

    /// Times `body` plus a display and a commit, in milliseconds of main-thread CPU.
    private static func timed(_ scene: DemoScene, _ body: () -> Void) -> Double {
        let start = LatencyClock.threadCPUNanoseconds()
        body()
        scene.surface.panel.displayIfNeeded()
        CATransaction.flush()
        return Double(LatencyClock.threadCPUNanoseconds() - start) / 1e6
    }

    /// Typing six queries into a 3,000-cell emoji grid, one character at a time, with matches
    /// emphasized. The filtered contents are computed first, because the engine filters in Rust
    /// within its own budget; the stand-in matcher's cost is reported beside it. `atlas` shows
    /// each emoji as a pre-rendered image, as the icon atlas would supply it; otherwise each one
    /// is a glyph typeset with Core Text on every draw.
    static func gridFiltering(atlas: Bool) async -> Result {
        let cells =
            atlas ? SyntheticComponents.glyphImageCells(count: 3000) : SyntheticComponents.glyphCells(count: 3000)
        var contents: [GridContent] = []
        var filterTimes: [Double] = []
        for query in gridQueries {
            for length in 1...query.count {
                let start = LatencyClock.now()
                let matches = SyntheticComponents.filter(cells, by: String(query.prefix(length)))
                filterTimes.append(LatencyClock.ms(start, LatencyClock.now()))
                contents.append(
                    GridContent(sections: [GridSection(cells: matches)], columns: .glyph, emphasizesMatches: true))
            }
            contents.append(GridContent(sections: [GridSection(cells: cells)], columns: .glyph))
        }
        let grid = GridView()
        let scene = makeScene(grid)
        grid.apply(contents.last ?? .empty)
        await pause(ms: 50)
        var samples: [Double] = []
        for round in 0..<3 {
            if round > 0 {
                scene.summoner.summon()
                await pause(ms: 50)
            }
            for (step, content) in contents.enumerated() {
                let cpu = timed(scene) {
                    grid.apply(content)
                    grid.select(content.cellCount > 0 ? 0 : nil, animated: false)
                }
                if round > 0 || step >= 5 { samples.append(cpu) }
                await pause(ms: 8)
            }
            scene.summoner.dismiss(returnFocus: false)
            await pause(ms: 500)
        }
        await finish(scene)
        return Result(
            label: atlas
                ? "grid filtering, 3,000 atlas image cells, apply + draw + commit"
                : "grid filtering, 3,000 live glyph cells, apply + draw + commit",
            cpu: LatencySummary(samples), budget: .rowUpdate,
            note: "stand-in matcher over 3,000 titles: p50 \(format(LatencySummary(filterTimes).p50, 3)) ms")
    }

    /// Streaming a Markdown answer into the detail pane twelve characters at a time.
    static func detailAppend() async -> Result {
        let split = ListDetailView()
        let scene = makeScene(split)
        split.list.apply(SyntheticComponents.historyRows())
        split.list.select(0, animated: false)
        let answer = String(repeating: SyntheticComponents.markdown + "\n\n", count: 4)
        let chunks = stride(from: 0, to: answer.count, by: 12).map { offset -> String in
            let start = answer.index(answer.startIndex, offsetBy: offset)
            return String(
                answer[start..<(answer.index(start, offsetBy: 12, limitedBy: answer.endIndex) ?? answer.endIndex)])
        }
        var samples: [Double] = []
        let perBatch = 120
        for batch in stride(from: 0, to: chunks.count, by: perBatch) {
            if batch > 0 {
                scene.summoner.summon()
                await pause(ms: 50)
            } else {
                split.detail.apply(DetailContent(body: .markdown(""), metadata: SyntheticComponents.metadata))
            }
            for chunk in chunks[batch..<min(batch + perBatch, chunks.count)] {
                samples.append(timed(scene) { split.detail.append(chunk) })
                await pause(ms: 8)
            }
            scene.summoner.dismiss(returnFocus: false)
            await pause(ms: 500)
        }
        await finish(scene)
        return Result(
            label: "detail Markdown append, 12 characters, + draw + commit",
            cpu: LatencySummary(Array(samples.dropFirst(5))),
            budget: .rowUpdate, note: "\(chunks.count) chunks, \(answer.count) characters")
    }

    /// Opening the action card over a list, and one keystroke into its filter. The host keeps one
    /// card and presents it again, as `LauncherSurface.present(_:)` advises; the first open of a
    /// new card is timed apart.
    static func actionCard() async -> (open: Result, filter: Result) {
        let list = ResultListView()
        let scene = makeScene(list)
        list.apply(SyntheticCatalog().rootContent())
        scene.surface.updateHeight(animated: false)
        scene.surface.accessibilityOverride = DisplayAccessibility(reduceMotion: true)
        let firstOpen = timed(scene) { scene.surface.present(ActionCardView(content: SyntheticComponents.actions)) }
        scene.surface.dismissOverlay()
        let card = ActionCardView(content: SyntheticComponents.actions)
        scene.surface.prewarm(card)
        var opens: [Double] = []
        var filters: [Double] = []
        for step in 0..<44 {
            card.apply(SyntheticComponents.actions)
            let open = timed(scene) { scene.surface.present(card) }
            let editor = scene.surface.panel.queryFieldEditor
            let filter = timed(scene) {
                editor.insertText("s", replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            editor.string = ""
            scene.surface.dismissOverlay()
            scene.surface.panel.displayIfNeeded()
            if step >= 4 {
                opens.append(open)
                filters.append(filter)
            }
            await pause(ms: 20)
            if step == 21 {
                scene.summoner.dismiss(returnFocus: false)
                await pause(ms: 500)
                scene.summoner.summon()
                await pause(ms: 50)
            }
        }
        await finish(scene)
        return (
            Result(
                label: "action card open, present + draw + commit", cpu: LatencySummary(opens), budget: .keystroke,
                note: "first open of a new card: \(format(firstOpen, 3)) ms"),
            Result(label: "action card filter keystroke", cpu: LatencySummary(filters), budget: .rowUpdate)
        )
    }
}
