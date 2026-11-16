import AppKit
import Foundation
import Kit
import KitHosting
import LauncherUI
import QuartzCore

/// The host's latency tables, measured on a real ``PanelController`` inside the app, for
/// `--bench`. Every number is main-thread CPU time; nothing waits on the wall clock.
///
/// - `typing`: keystrokes through the search field's editor into root search, with Root's query,
///   the list's draw and the commit. Budget: the keystroke budget in docs/ARCHITECTURE.md. A
///   second line leaves out Root and LauncherUI, for comparison.
/// - `summon`: showing the panel, minus `makeKey`. Budget 1 ms.
/// - `actions`: opening the action panel, with its draw and commit. Budget 8 ms p99.
/// - `push`: pushing a list page, with its draw and commit. Budget 8 ms p99.
/// - `grid`: filtering a grid of 3,000 image cells per keystroke: the host's work and the grid's
///   apply, without the fuzzy index search. Budget 2 ms p50, 4.5 ms p99.
/// - `detail`: one streamed append drawn into a detail page. Budget 1 ms p50.
/// - `summon-key`: only when named. Summons with key status, as the live launcher does, in the
///   summoner's order. See ``keySummons()``.
///
/// The panel shows in the bottom-left corner without key status, for under two seconds per batch,
/// and is hidden between batches.
///
/// ```swift
/// let passed = await HostBench(panel: panel).run()   // prints the table, then "bench PASS"
/// ```
@MainActor public final class HostBench {
    /// One measured path.
    public struct Line: Sendable, Equatable {
        public var name: String
        public var samples: Int
        public var p50: Double
        public var p99: Double
        public var budgetP50: Double?
        public var budgetP99: Double?
        /// Printed after the numbers, such as what the row leaves out.
        public var note: String?

        public var passed: Bool {
            (budgetP50.map { p50 <= $0 } ?? true) && (budgetP99.map { p99 <= $0 } ?? true)
        }
    }

    /// Every bench, in the order they run.
    public static let names = ["typing", "summon", "actions", "push", "grid", "detail"]
    /// Benches that take key status. They run only when named, and only while nobody types.
    public static let keyNames = ["summon-key"]

    public let panel: PanelController
    /// Multiplies every budget, for slower machines. `LATENCY_BUDGET_SCALE` sets it by default.
    public var budgetScale = LatencyBudget.environmentScale
    /// Where lines go. Standard output by default.
    public var log: (String) -> Void = { line in
        print(line)
        fflush(stdout)
    }

    public private(set) var lines: [Line] = []

    /// - Parameters:
    ///   - placesInCorner: Moves the panel to the bottom-left corner of the main screen.
    public init(panel: PanelController, placesInCorner: Bool = true) {
        self.panel = panel
        panel.summoner.takesKeyStatus = false
        panel.summoner.followsPointerScreen = false
        if placesInCorner, let visible = NSScreen.main?.visibleFrame {
            panel.surface.place(windowOrigin: CGPoint(x: visible.minX + 16, y: visible.minY + 16))
        }
    }

    /// Runs the named benches, or all of them, prints the table and `bench PASS` or `bench FAIL`.
    @discardableResult
    public func run(_ only: Set<String>? = nil) async -> Bool {
        lines = []
        let load = Self.loadAverage()
        log(String(format: "host bench, 1-minute load average %.2f", load))
        let keyNames = Self.keyNames.filter { only?.contains($0) == true }
        for name in Self.names + keyNames where only?.contains(name) ?? true {
            switch name {
            case "typing": await typing()
            case "summon": summons()
            case "actions": await actionPanel()
            case "push": await pushes()
            case "grid": await grid()
            case "detail": await detail()
            case "summon-key": await keySummons()
            default: break
            }
            await pause(300)
        }
        log(table())
        let passed = lines.allSatisfy(\.passed)
        log(passed ? "bench PASS" : "bench FAIL")
        return passed
    }

    // MARK: Benches

    private static let queries = ["s", "sa", "sam", "samp", "sampl", "sample"]

    /// Keystrokes through the field editor: the field editor's work, the host's, Root's query and
    /// LauncherUI's draw, then the commit.
    private func typing() async {
        panel.summon()
        defer { panel.dismiss() }
        let field = panel.surface.queryField
        let meter = panel.workMeter
        meter.isEnabled = true
        defer { meter.isEnabled = false }
        if field.textField.currentEditor() == nil { field.installEditor() }
        guard let editor = field.textField.currentEditor() as? NSTextView else {
            log("typing: the search field has no editor")
            return
        }
        var whole: [Double] = []
        var host: [Double] = []
        var handled: [Double] = []
        var drawn: [Double] = []
        let word = "sample item"
        for round in 0..<14 {
            for character in word {
                let sample = measure {
                    meter.reset()
                    editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
                }
                if round > 0 {
                    whole.append(sample.cpu)
                    host.append(sample.handler - Double(meter.calledNanoseconds) / 1e6)
                    handled.append(sample.handler)
                    drawn.append(sample.cpu - sample.handler)
                }
            }
            for _ in word {
                let sample = measure {
                    meter.reset()
                    editor.deleteBackward(nil)
                }
                if round > 0 {
                    whole.append(sample.cpu)
                    host.append(sample.handler - Double(meter.calledNanoseconds) / 1e6)
                    handled.append(sample.handler)
                    drawn.append(sample.cpu - sample.handler)
                }
            }
            await pause(1)
        }
        add("keystroke, field editor to commit", whole, budget: LatencyBudget.keystroke)
        add(
            "keystroke, field editor and host", host, budget: nil,
            note: "without Root's query and LauncherUI's calls; no budget of its own")
        add(
            "keystroke, up to the draw", handled, budget: nil,
            note: "field editor, host, Root and LauncherUI's apply; the split of the first line")
        add(
            "keystroke, draw and commit", drawn, budget: nil,
            note: "displayIfNeeded and the Core Animation commit; the rest of the first line")
    }

    private func summons() {
        var samples: [Double] = []
        for step in 0..<210 {
            let start = LatencyClock.threadCPUNanoseconds()
            panel.summon()
            let cpu = Double(LatencyClock.threadCPUNanoseconds() - start) / 1e6
            if step >= 10 { samples.append(cpu - panel.summoner.lastTimings.makeKey) }
            panel.summoner.dismiss(returnFocus: false)
        }
        add("summon minus makeKey", samples, budget: LatencyBudget(p50: 1, p99: 1))
    }

    private func actionPanel() async {
        panel.summon()
        defer { panel.dismiss() }
        let field = panel.surface.queryField
        field.text = "sa"
        panel.queryField(field, didChangeText: "sa")
        var samples: [Double] = []
        for step in 0..<70 {
            let sample = measure { panel.openActionPanel() }
            if step >= 10 { samples.append(sample.cpu) }
            panel.surface.dismissOverlay()
            commit()
            _ = panel.queryField(field, perform: step.isMultiple(of: 2) ? .moveDown : .moveUp)
            await pause(1)
        }
        add("action panel open", samples, budget: LatencyBudget(p50: 8, p99: 8))
    }

    private func pushes() async {
        panel.summon()
        defer { panel.dismiss() }
        let origin = benchOrigin
        let page = ListPage(
            sections: [ListSection("Recent", rows: Self.rows(40, symbol: "doc.text"))], title: "Bench List",
            actions: { _ in [Action("Open", id: "open") { _ in .keepOpen }] })
        var samples: [Double] = []
        for step in 0..<90 {
            let made = panel.makePage(.list(page), origin: origin)
            let sample = measure { panel.push(made) }
            if step >= 10 { samples.append(sample.cpu) }
            panel.pop()
            commit()
            if step % 10 == 9 { await pause(1) }
        }
        add("page push", samples, budget: LatencyBudget(p50: 8, p99: 8), note: "the page's load runs after it")
    }

    /// 3,000 image cells, filtered per keystroke.
    private func grid() async {
        panel.summon()
        defer {
            panel.popToRoot()
            panel.dismiss()
        }
        let source = BenchGridSource(count: 3000)
        let page = GridPage(source, title: "Bench Grid", columns: 8, showsTitles: false)
        guard let grid = panel.makePage(.grid(page), origin: benchOrigin) as? GridPageController else { return }
        panel.push(grid)
        for _ in 0..<500 where grid.loadCount == 0 { await pause(2) }
        guard grid.loadCount > 0 else {
            log("grid: the page did not load")
            return
        }
        let meter = panel.workMeter
        meter.isEnabled = true
        defer { meter.isEnabled = false }
        let field = panel.surface.queryField
        var samples: [Double] = []
        var drawn: [Double] = []
        var searches: [Double] = []
        var cells = 0
        let words = ["s", "su", "sun", "suns", "sunse", "sunset", "sunse", "suns", "sun", "su", "s", ""]
        for step in 0..<264 {
            let text = words[step % words.count]
            field.text = text
            meter.reset()
            let start = LatencyClock.threadCPUNanoseconds()
            panel.queryField(field, didChangeText: text)
            let handled = LatencyClock.threadCPUNanoseconds()
            commit()
            let committed = LatencyClock.threadCPUNanoseconds()
            if step >= 24 {
                let search = Double(meter.searchNanoseconds) / 1e6
                samples.append(Double(handled - start) / 1e6 - search)
                drawn.append(Double(committed - start) / 1e6 - search)
                searches.append(search)
                cells += grid.grid.content.cellCount
            }
            if step % 12 == 11 { await pause(1) }
        }
        add(
            "grid filter, 3,000 image cells", samples, budget: LatencyBudget.rowUpdate,
            note: "host work and grid apply, not the index search or the draw; "
                + "\(cells / max(1, samples.count)) cells shown on average")
        add("grid filter with draw and commit", drawn, budget: nil, note: "for comparison, no budget")
        add("grid filter, fuzzy index search alone", searches, budget: nil, note: "the index's work, not the host's")
    }

    /// One append to a streaming answer, drawn at once.
    private func detail() async {
        panel.summon()
        defer {
            panel.popToRoot()
            panel.dismiss()
        }
        let source = BenchDetailSource()
        guard
            let page = panel.makePage(.detail(DetailPage(title: "Bench Answer", source: source)), origin: benchOrigin)
                as? DetailPageController
        else { return }
        panel.push(page)
        page.applyNow(.replace(.markdown("# Answer\n\n")))
        let meter = panel.workMeter
        meter.isEnabled = true
        defer { meter.isEnabled = false }
        var samples: [Double] = []
        var applied: [Double] = []
        var host: [Double] = []
        for step in 0..<320 {
            let token = step.isMultiple(of: 40) ? "\n\nNext paragraph with `code` " : "word\(step % 7) "
            meter.reset()
            let sample = measure { page.applyNow(.append(token)) }
            if step >= 20 {
                samples.append(sample.cpu)
                applied.append(sample.handler)
                host.append(sample.handler - Double(meter.calledNanoseconds) / 1e6)
            }
            if step % 40 == 39 { await pause(1) }
        }
        add("detail append, draw and commit", samples, budget: LatencyBudget(p50: 1, p99: .infinity))
        add("detail append without the draw", applied, budget: nil, note: "the host's part and the pane's append")
        add("detail append, host's part", host, budget: nil, note: "without the pane's append and the draw")
    }

    // MARK: Helpers

    private var benchOrigin: RunOrigin {
        RunOrigin(featureID: HostSettings.namespace, feature: panel.runtime.hostContext, launch: .page)
    }

    /// Runs `body`, then draws and commits. Returns the CPU of the whole and of `body` alone, in ms.
    private func measure(_ body: () -> Void) -> (cpu: Double, handler: Double) {
        let start = LatencyClock.threadCPUNanoseconds()
        body()
        let handled = LatencyClock.threadCPUNanoseconds()
        commit()
        let end = LatencyClock.threadCPUNanoseconds()
        return (Double(end - start) / 1e6, Double(handled - start) / 1e6)
    }

    private func commit() {
        panel.surface.panel.displayIfNeeded()
        CATransaction.flush()
    }

    func add(_ name: String, _ samples: [Double], budget: LatencyBudget?, note: String? = nil) {
        let summary = LatencySummary(samples)
        let scale = budgetScale
        lines.append(
            Line(
                name: name, samples: summary.count, p50: summary.p50, p99: summary.p99,
                budgetP50: budget.map { $0.p50 * scale }, budgetP99: budget.map { $0.p99 * scale }, note: note))
    }

    /// The results as a text table.
    public func table() -> String {
        var text = ["path | n | p50 ms | p99 ms | budget p50 / p99 ms | verdict"]
        for row in lines {
            func budget(_ value: Double?) -> String {
                guard let value, value.isFinite else { return "-" }
                return String(format: "%.1f", value)
            }
            let verdict = row.budgetP50 == nil && row.budgetP99 == nil ? "info" : (row.passed ? "PASS" : "FAIL")
            var line = String(
                format: "%@ | %d | %.3f | %.3f | %@ / %@ | %@", row.name, row.samples, row.p50, row.p99,
                budget(row.budgetP50), budget(row.budgetP99), verdict)
            if let note = row.note { line += " (\(note))" }
            text.append(line)
        }
        return text.joined(separator: "\n")
    }

    func pause(_ milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    /// The 1-minute load average.
    nonisolated static func loadAverage() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) > 0 ? loads[0] : -1
    }

    nonisolated static func rows(_ count: Int, symbol: String) -> [Kit.Row] {
        (0..<count).map { index in
            Kit.Row(id: ItemID("bench", String(index)), title: "Sample Entry \(index)", icon: .symbol(symbol))
        }
    }
}

/// 3,000 image rows whose keywords give queries something to narrow.
@MainActor final class BenchGridSource: ListSource {
    private let rows: [Row]

    init(count: Int) {
        let words = ["sunset", "sunrise", "harbor", "summit", "forest", "street", "studio", "sand", "snow", "stone"]
        rows = (0..<count).map { index in
            let word = words[index % words.count]
            return Row(
                id: ItemID("bench-grid", String(index)), title: "\(word) \(index)", icon: .symbol("photo"),
                keywords: [word, "image"])
        }
    }

    func load(_ request: ListRequest) async throws -> ListResult {
        ListResult(sections: [ListSection("Images", id: "images", rows: rows)])
    }

    func actions(for row: Row) -> [Action] {
        [Action("Open", id: "open") { _ in .keepOpen }, Action("Copy", id: "copy") { _ in .keepOpen }]
    }
}

/// A detail source whose stream never sends; the bench applies updates itself.
@MainActor final class BenchDetailSource: DetailSource {
    func start() -> AsyncThrowingStream<DetailUpdate, any Error> {
        AsyncThrowingStream { _ in }
    }

    func actions(for detail: Detail) -> [Action] {
        [Action("Copy Answer", id: "copy") { _ in .keepOpen }]
    }
}
