import AppKit
import LauncherUITesting
import QuartzCore
import Testing

@_spi(Testing) @testable import LauncherUI

/// Main-thread budgets from docs/ARCHITECTURE.md, measured deterministically: the work, then an
/// explicit display and commit. Debug builds are 5 to 10 times slower, so these run only in a
/// release build: `swift test -c release` (or `make test-LauncherUI-budget`). A test runner is a
/// terminal process with lower scheduling priority than the app, so these bounds are pessimistic;
/// `LATENCY_BUDGET_SCALE` relaxes them on slower machines. The app-bundle numbers come from
/// `make ui-bench`.
@Suite(.enabled(if: BudgetBuild.isRelease, "budgets run in release builds only"), .timeLimit(.minutes(3)))
struct LatencyBudgetTests {
    let scale = LatencyBudget.environmentScale

    /// The lab's method: drop warm-up samples, then nearest-rank percentiles.
    func measure(_ count: Int, warmUp: Int = 20, _ body: (Int) -> Void) -> LatencySummary {
        var samples: [Double] = []
        samples.reserveCapacity(count)
        for step in 0..<(count + warmUp) {
            let start = LatencyClock.now()
            body(step)
            if step >= warmUp { samples.append(LatencyClock.ms(start, LatencyClock.now())) }
        }
        return LatencySummary(samples)
    }

    @Test func nineChangedRowsFitTheRowUpdateBudget() {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        let list = ResultListView()
        surface.setContent(list, animated: false)
        surface.panel.orderFrontRegardless()
        let catalog = SyntheticCatalog()
        let contents = (0..<8).map { catalog.rotatingContent(step: $0) }
        let summary = measure(300) { step in
            list.apply(contents[step % contents.count])
            surface.panel.displayIfNeeded()
            CATransaction.flush()
        }
        print("row update, 9 changed rows, apply + draw + commit (ms): \(summary)")
        #expect(LatencyBudget.rowUpdate.violation(summary, label: "row update", scale: scale) == nil)
    }

    /// The row update split into its parts: the list's apply, its draw, the rest of the panel's
    /// draw, and the Core Animation commit. Each is main-thread CPU. The whole must fit the row
    /// update budget; the parts are printed so a regression shows where it lands.
    @Test func theRowUpdateSplitsIntoApplyDrawAndCommit() async {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        let list = ResultListView()
        surface.setContent(list, animated: false)
        surface.panel.orderFrontRegardless()
        let catalog = SyntheticCatalog()
        let contents = (0..<8).map { catalog.rotatingContent(step: $0) }
        var parts: [[Double]] = Array(repeating: [], count: 5)
        for step in 0..<420 {
            var times: [UInt64] = [LatencyClock.threadCPUNanoseconds()]
            list.apply(contents[step % contents.count])
            times.append(LatencyClock.threadCPUNanoseconds())
            list.displayIfNeeded()
            times.append(LatencyClock.threadCPUNanoseconds())
            surface.panel.displayIfNeeded()
            times.append(LatencyClock.threadCPUNanoseconds())
            CATransaction.flush()
            times.append(LatencyClock.threadCPUNanoseconds())
            guard step >= 20 else { continue }
            for part in 0..<4 { parts[part].append(Double(times[part + 1] - times[part]) / 1e6) }
            parts[4].append(Double(times[4] - times[0]) / 1e6)
            if step.isMultiple(of: 20) { try? await Task.sleep(for: .milliseconds(8)) }
        }
        let names = ["apply", "list draw", "rest of the panel's draw", "commit", "whole"]
        for (name, samples) in zip(names, parts) { print("row update split, \(name) (ms): \(LatencySummary(samples))") }
        let draw = Self.typesetAndRender(contents, theme: list.theme ?? TestSupport.lightTheme)
        print("row update split, list draw: typeset 9 rows (ms): \(draw.typeset)")
        print("row update split, list draw: render 9 rows into a bitmap (ms): \(draw.render)")
        #expect(LatencyBudget.rowUpdate.violation(LatencySummary(parts[4]), label: "row update", scale: scale) == nil)
    }

    /// Typing into a full list in the panel: apply, draw and commit, with rounds alternating
    /// between the list's line cache and none, so both see the same load. Each round types its
    /// queries into a fresh cache.
    @Test func typingIntoTheListFitsTheRowUpdateBudget() async {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        let list = ResultListView()
        surface.setContent(list, animated: false)
        surface.panel.orderFrontRegardless()
        let catalog = SyntheticCatalog()
        var contents: [ListContent] = []
        for query in ["aurora", "cobalt term", "clip hist", "window left", "convert", "search emo", "basil"] {
            for length in 1...query.count { contents.append(catalog.content(for: String(query.prefix(length)))) }
            contents.append(catalog.rootContent())
        }
        var cached: [Double] = []
        var uncached: [Double] = []
        for round in 0..<12 {
            list.usesLineCache = round.isMultiple(of: 2)
            list.lineCache.removeAll()
            for content in contents {
                let start = LatencyClock.threadCPUNanoseconds()
                list.apply(content)
                list.select(content.rowCount > 0 ? 0 : nil, animated: false)
                surface.panel.displayIfNeeded()
                CATransaction.flush()
                let cpu = Double(LatencyClock.threadCPUNanoseconds() - start) / 1e6
                if round > 1 {
                    if list.usesLineCache { cached.append(cpu) } else { uncached.append(cpu) }
                }
            }
            try? await Task.sleep(for: .milliseconds(8))
        }
        print("typing into the list, apply + draw + commit, without the line cache (ms): \(LatencySummary(uncached))")
        print("typing into the list, apply + draw + commit, with the line cache (ms): \(LatencySummary(cached))")
        #expect(LatencyBudget.rowUpdate.violation(LatencySummary(cached), label: "typing", scale: scale) == nil)
    }

    /// Typesetting the rows each keystroke shows while typing, with and without the line cache the
    /// list keeps. Each query is typed once into a fresh cache, so titles whose highlights change
    /// are typeset again and only text that repeats is found. The cache must not cost more than
    /// it saves.
    @Test func theLineCachePaysForItselfWhileTyping() {
        let theme = TestSupport.lightTheme
        let catalog = SyntheticCatalog()
        let queries = ["aurora", "cobalt term", "clip hist", "window left", "convert", "search emo", "basil"]
        let typed = queries.map { query in
            (1...query.count).map { catalog.content(for: String(query.prefix($0)), limit: 9) }
        }
        func run(cached: Bool) -> LatencySummary {
            var samples: [Double] = []
            for round in 0..<6 {
                for keystrokes in typed {
                    let cache = cached ? RowLineCache() : nil
                    for content in keystrokes {
                        let start = LatencyClock.threadCPUNanoseconds()
                        for row in content.sections.flatMap(\.rows) {
                            _ = RowTypesetter.typeset(
                                row, width: 760, height: 44, style: .oneLine, emphasizesMatches: true, theme: theme,
                                scale: 2, lines: cache)
                        }
                        if round > 0 { samples.append(Double(LatencyClock.threadCPUNanoseconds() - start) / 1e6) }
                    }
                }
            }
            return LatencySummary(samples)
        }
        let without = run(cached: false)
        let with = run(cached: true)
        print("typeset a keystroke's rows, each query fresh, without the line cache (ms): \(without)")
        print("typeset a keystroke's rows, each query fresh, with the line cache (ms): \(with)")
        #expect(with.p50 <= without.p50)
    }

    /// A streamed Markdown append to the detail pane, split into the pane's append, the draw and
    /// the commit, with the host bench's tokens: a word at a time and a new paragraph every 40.
    @Test func theDetailAppendSplitsIntoAppendDrawAndCommit() async {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        let split = ListDetailView()
        surface.setContent(split, animated: false)
        surface.panel.orderFrontRegardless()
        split.list.apply(SyntheticComponents.historyRows())
        split.detail.apply(DetailContent(body: .markdown("# Answer\n\n"), metadata: SyntheticComponents.metadata))
        surface.panel.displayIfNeeded()
        var parts: [[Double]] = Array(repeating: [], count: 4)
        for step in 0..<420 {
            let token = step.isMultiple(of: 40) ? "\n\nNext paragraph with `code` " : "word\(step % 7) "
            let start = LatencyClock.threadCPUNanoseconds()
            split.detail.append(token)
            let appended = LatencyClock.threadCPUNanoseconds()
            surface.panel.displayIfNeeded()
            let drawn = LatencyClock.threadCPUNanoseconds()
            CATransaction.flush()
            let committed = LatencyClock.threadCPUNanoseconds()
            guard step >= 20 else { continue }
            parts[0].append(Double(appended - start) / 1e6)
            parts[1].append(Double(drawn - appended) / 1e6)
            parts[2].append(Double(committed - drawn) / 1e6)
            parts[3].append(Double(committed - start) / 1e6)
            if step.isMultiple(of: 40) { try? await Task.sleep(for: .milliseconds(8)) }
        }
        for (name, samples) in zip(["append", "draw", "commit", "whole"], parts) {
            print("detail append split, \(name) (ms): \(LatencySummary(samples))")
        }
        #expect(LatencySummary(parts[3]).p50 <= 1.5 * scale)
    }

    /// Filtering a 3,000-cell grid one character at a time: apply, draw and commit, for live glyph
    /// cells and for atlas images.
    @Test(arguments: [false, true])
    func theGridFilterFitsTheRowUpdateBudget(atlas: Bool) async {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        let grid = GridView()
        surface.setContent(grid, animated: false)
        surface.panel.orderFrontRegardless()
        let cells =
            atlas ? SyntheticComponents.glyphImageCells(count: 3000) : SyntheticComponents.glyphCells(count: 3000)
        var contents: [GridContent] = []
        for query in ["amber", "harbor sage", "tide", "zephyr", "quartz moss", "lumen"] {
            for length in 1...query.count {
                let matches = SyntheticComponents.filter(cells, by: String(query.prefix(length)))
                contents.append(
                    GridContent(sections: [GridSection(cells: matches)], columns: .glyph, emphasizesMatches: true))
            }
            contents.append(GridContent(sections: [GridSection(cells: cells)], columns: .glyph))
        }
        var samples: [Double] = []
        for round in 0..<6 {
            for content in contents {
                let start = LatencyClock.threadCPUNanoseconds()
                grid.apply(content)
                grid.select(content.cellCount > 0 ? 0 : nil, animated: false)
                surface.panel.displayIfNeeded()
                CATransaction.flush()
                if round > 0 { samples.append(Double(LatencyClock.threadCPUNanoseconds() - start) / 1e6) }
            }
            try? await Task.sleep(for: .milliseconds(8))
        }
        let summary = LatencySummary(samples)
        print("grid filter, \(atlas ? "atlas" : "glyph") cells, apply + draw + commit (ms): \(summary)")
        #expect(LatencyBudget.rowUpdate.violation(summary, label: "grid filter", scale: scale) == nil)
    }

    /// The list draw's two halves outside AppKit: typesetting nine new rows, and rendering them
    /// into a bitmap at the display's scale.
    static func typesetAndRender(_ contents: [ListContent], theme: ResolvedTheme) -> (
        typeset: LatencySummary, render: LatencySummary
    ) {
        let width: CGFloat = 760
        let height = CGFloat(theme.theme.list.rowHeight)
        let scale: CGFloat = 2
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let context = CGContext(
            data: nil, width: Int(width * scale), height: Int(height * 9 * scale), bitsPerComponent: 8,
            bytesPerRow: 0, space: space, bitmapInfo: info)!
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: 0, y: -height * 9)
        var typesetTimes: [Double] = []
        var renderTimes: [Double] = []
        for step in 0..<320 {
            let rows = contents[step % contents.count].sections[0].rows
            let start = LatencyClock.threadCPUNanoseconds()
            let typesets = rows.map {
                RowTypesetter.typeset(
                    $0, width: width, height: height, style: .oneLine, emphasizesMatches: true, theme: theme,
                    scale: scale)
            }
            let typeset = LatencyClock.threadCPUNanoseconds()
            context.clear(CGRect(x: 0, y: 0, width: width, height: height * 9))
            for (index, typeset) in typesets.enumerated() {
                RowRenderer.drawRow(
                    typeset, icon: rows[index].icon, at: CGPoint(x: 0, y: CGFloat(index) * height), in: context,
                    theme: theme)
            }
            let rendered = LatencyClock.threadCPUNanoseconds()
            guard step >= 20 else { continue }
            typesetTimes.append(Double(typeset - start) / 1e6)
            renderTimes.append(Double(rendered - typeset) / 1e6)
        }
        return (LatencySummary(typesetTimes), LatencySummary(renderTimes))
    }

    @Test func summonWithoutMakeKeyFitsTheSummonBudget() {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        let summoner = Summoner(surface: surface)
        summoner.followsPointerScreen = false
        summoner.takesKeyStatus = false
        summoner.prewarm()
        var steps: [Double] = []
        let pointer = measure(200) { _ in _ = LauncherSurface.screenWithPointer()?.visibleFrame }
        let summary = measure(100, warmUp: 5) { _ in
            summoner.summon()
            steps.append(summoner.lastTimings.excludingMakeKey)
            summoner.dismiss(returnFocus: false)
        }
        let path = LatencySummary(Array(steps.dropFirst(5)))
        print(
            "summon path excluding makeKey (ms): \(path); summon + dismiss: \(summary); pointer screen check: \(pointer)"
        )
        // The budget covers the summon path plus the pointer-screen check that precedes it.
        #expect(path.p50 + pointer.p50 <= LatencyBudget.summon.p50 * scale)
        #expect(path.p99 + pointer.p99 <= LatencyBudget.summon.p99 * scale)
    }

    @Test func theProbeCostsMicroseconds() {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        let probe = LatencyProbe(view: surface.rootView)
        let summary = measure(2000) { _ in
            probe.begin(.keystroke)
            probe.markApplied()
        }
        print("probe begin + markApplied (ms): \(summary)")
        #expect(summary.p50 < 0.01 * scale)
    }
}

nonisolated enum BudgetBuild {
    static var isRelease: Bool {
        #if DEBUG
            false
        #else
            true
        #endif
    }
}
