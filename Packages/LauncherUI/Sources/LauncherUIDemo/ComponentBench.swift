import AppKit
@_spi(Testing) import LauncherUI
import LauncherUITesting

/// Main-thread cost of the part 2 components, measured like the row update: the work, then an
/// explicit display and commit, timed as the main thread's CPU. The panel shows without key status,
/// each batch waits for 15 s of idle input, and each stays on screen under two seconds.
enum ComponentBench {
    struct Result {
        let label: String
        let cpu: LatencySummary
        let budget: LatencyBudget
        var note = ""
    }

    static let gridQueries = ["amber", "harbor sage", "tide", "zephyr", "quartz moss", "lumen"]

    /// A scene showing `content` without key status in the corner, not yet summoned.
    private static func makeScene(_ content: any LauncherContentView, theme: Theme = .standard) -> DemoScene {
        let scene = DemoScene(theme: theme)
        scene.summoner.prewarm()
        scene.summoner.takesKeyStatus = false
        scene.surface.setContent(content, animated: false)
        scene.surface.updateHeight(animated: false)
        return scene
    }

    /// Summons once the Mac has been idle for 15 s. False when it never was.
    private static func show(_ scene: DemoScene) async -> Bool {
        guard await BenchMode.idle() else { return false }
        scene.summoner.summon()
        await pause(ms: 50)
        return true
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
        var samples: [Double] = []
        for round in 0..<3 {
            guard await show(scene) else { break }
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
            if batch == 0 {
                split.detail.apply(DetailContent(body: .markdown(""), metadata: SyntheticComponents.metadata))
            }
            guard await show(scene) else { break }
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
    /// Where an action card open goes, from the last `actionCard()` run.
    struct OpenSplit {
        var present: [Double] = []
        var display: [Double] = []
        var commit: [Double] = []
        /// Whole opens by line cache mode, with `compare`.
        var byMode: [String: [Double]] = [:]
    }

    /// Alternate the card's line cache off and on, open by open.
    static var compare = false

    static var lastOpenSplit = OpenSplit()

    static func actionCard(theme: Theme = .standard) async -> (open: Result, filter: Result) {
        let list = ResultListView()
        let scene = makeScene(list, theme: theme)
        list.apply(SyntheticCatalog().rootContent())
        scene.surface.updateHeight(animated: false)
        scene.surface.accessibilityOverride = DisplayAccessibility(reduceMotion: true)
        guard await show(scene) else {
            await finish(scene)
            let none = Result(label: "action card open", cpu: LatencySummary([]), budget: .keystroke, note: "no idle")
            return (none, none)
        }
        let firstOpen = timed(scene) { scene.surface.present(ActionCardView(content: SyntheticComponents.actions)) }
        scene.surface.dismissOverlay()
        let card = ActionCardView(content: SyntheticComponents.actions)
        scene.surface.prewarm(card)
        var opens: [Double] = []
        var filters: [Double] = []
        var split = OpenSplit()
        for step in 0..<44 {
            card.apply(SyntheticComponents.actions)
            // `compare` turns the card's line cache off for every other open, so both see the same load.
            if compare { card.usesLineCache = step % 2 == 1 }
            let start = LatencyClock.threadCPUNanoseconds()
            scene.surface.present(card)
            let presented = LatencyClock.threadCPUNanoseconds()
            scene.surface.panel.displayIfNeeded()
            let drawn = LatencyClock.threadCPUNanoseconds()
            CATransaction.flush()
            let committed = LatencyClock.threadCPUNanoseconds()
            let open = Double(committed - start) / 1e6
            if step >= 4 {
                split.present.append(Double(presented - start) / 1e6)
                split.display.append(Double(drawn - presented) / 1e6)
                split.commit.append(Double(committed - drawn) / 1e6)
                if compare {
                    split.byMode[step % 2 == 1 ? "line cache" : "no line cache", default: []].append(
                        Double(committed - start) / 1e6)
                }
            }
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
                guard await show(scene) else { break }
            }
        }
        await finish(scene)
        lastOpenSplit = split
        return (
            Result(
                label: "action card open, present + draw + commit", cpu: LatencySummary(opens), budget: .keystroke,
                note: "first open of a new card: \(format(firstOpen, 3)) ms"),
            Result(label: "action card filter keystroke", cpu: LatencySummary(filters), budget: .rowUpdate)
        )
    }
}
