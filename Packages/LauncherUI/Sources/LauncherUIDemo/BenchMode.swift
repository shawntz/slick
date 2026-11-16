import AppKit
import LauncherUI
import LauncherUITesting

/// Prints the latency tables and checks the budgets, measured inside an app bundle:
/// summon strategies (with key status, against ScreenCaptureKit display times), updating nine
/// changed rows, a keystroke split into its parts, the lens glide, the glass height animation and
/// the components.
///
/// `themes=standard,beam,clear` picks the themes; all three run by default. Standard's summon runs
/// every strategy; the others run the default one. The grid and detail measures run for Standard
/// alone, because no theme changes how they draw beyond its metrics; the action card, the glass
/// height and the first results after a compact summon run per theme.
/// `parts=summon,rows,keystroke,motion,components` picks the parts; all run by default. `parts=card`
/// splits the action card's open into present, display and commit; with `compare=1` it turns the
/// card's line cache off for every other open. Only the
/// summon part takes key status, about 120 ms per summon; each of its batches waits for 120 s of
/// idle input and stops the moment input arrives. Every other batch waits for 15 s of idle input
/// first, shows the panel in a corner without key status, and stays on screen under two seconds.
enum BenchMode {
    static let allParts = ["summon", "rows", "keystroke", "motion", "components"]

    /// Waits until nobody has touched the keyboard or mouse for 15 s. False when that never
    /// happens within half an hour or the idle time cannot be read.
    static func idle() async -> Bool {
        await IdleGate.wait(seconds: 15, interval: 1, until: Date().addingTimeInterval(1800))
    }

    static func run(_ options: DemoOptions) async -> Bool {
        let cycles = options.int("summons", 18)
        let parts = Set(options.string("parts", allParts.joined(separator: ",")).split(separator: ",").map(String.init))
        let names = options.string("themes", ShotsMode.defaultThemes).split(separator: ",").map { $0.lowercased() }
        let themes = names.compactMap { name in ThemeStore.builtInThemes.first { $0.name.lowercased() == name } }
        guard themes.count == names.count, !themes.isEmpty else {
            say("bench: unknown theme in \(names)")
            return false
        }
        var verdicts: [String] = []
        var passed = true
        if parts.contains("summon") {
            for named in themes {
                passed = await summon(cycles: cycles, theme: named, verdicts: &verdicts) && passed
            }
        }
        if parts.contains("rows") {
            for named in themes {
                passed = await rows(theme: named, verdicts: &verdicts) && passed
            }
        }
        if parts.contains("keystroke") {
            for named in themes {
                // `compare=1` first types without the list's line cache, for a before and after.
                if options.int("compare", 0) == 1 {
                    _ = await keystroke(
                        passes: options.int("passes", 3), lineCache: false, theme: named, verdicts: &verdicts)
                }
                passed =
                    await keystroke(
                        passes: options.int("passes", 3), lineCache: true, theme: named, verdicts: &verdicts)
                    && passed
            }
        }
        if parts.contains("motion") {
            await motion(themes: themes)
        }
        if parts.contains("components") {
            passed = await components(themes: themes, verdicts: &verdicts) && passed
        }
        if parts.contains("card") {
            // `compare=1` alternates the card's line cache off and on, open by open.
            ComponentBench.compare = options.int("compare", 0) == 1
            var modes: [String: [Double]] = [:]
            for _ in 0..<max(1, options.int("cardRounds", 1)) {
                passed = await actionCard(verdicts: &verdicts) && passed
                for (mode, samples) in ComponentBench.lastOpenSplit.byMode { modes[mode, default: []] += samples }
            }
            for (mode, samples) in modes.sorted(by: { $0.key < $1.key }) {
                say("whole open, \(mode): n=\(samples.count) min / p50 / p99 \(triple(samples))")
            }
        }
        say("\n## Budgets")
        for verdict in verdicts { say(verdict) }
        return passed
    }

    private static func summon(cycles: Int, theme named: NamedTheme, verdicts: inout [String]) async -> Bool {
        var passed = true
        say("## Summon, \(named.name) (key status, n=\(cycles) per row; times from the trigger, ms)")
        var summonTable = TextTable([
            "strategy", "key first", "ramp", "path excl. makeKey p50/p99", "makeKey p50/p99", "first pixels p50/p99",
            "key look p50/p99", "frames 1-5, share of the key look",
        ])
        var paths: [Double] = []  // the default strategy's, which the budget covers
        let all = [
            (SummonStrategy.layerOpacity, true, 0), (.layerOpacity, false, 0), (.layerOpacity, false, 2),
            (.orderFront, false, 0),
        ]
        for (strategy, keyFirst, ramp) in named.name == ThemeStore.standardName ? all : [all[0]] {
            let result = await SummonBench.run(
                strategy: strategy, rampFrames: ramp, keyFirst: keyFirst, cycles: cycles, theme: named.theme)
            if result.interrupted {
                verdicts.append("summon: input arrived; the run stopped: FAIL")
                return false
            }
            if strategy == .layerOpacity, keyFirst, ramp == Theme.standard.motion.summonRampFrames {
                paths = result.paths
            }
            let trajectory = SummonBench.medianTrajectory(result.trajectories).map { format($0) }.joined(separator: " ")
            summonTable.add([
                strategy.rawValue, keyFirst ? "yes" : "no", "\(ramp)", pair(result.paths), pair(result.makeKey),
                pair(result.firstPixels), pair(result.keyLook), trajectory,
            ])
        }
        say(summonTable.render())
        let pointer = measure(200) { _ = LauncherSurface.screenWithPointer()?.visibleFrame }
        let path = LatencySummary(paths)
        say("pointer-screen check (ms): \(pointer)")
        let summonP99 = path.p99 + pointer.p99
        let summonOK = path.p50 + pointer.p50 <= LatencyBudget.summon.p50 && summonP99 <= LatencyBudget.summon.p99
        verdicts.append(
            String(
                format:
                    "%@ summon path (default strategy) excluding makeKey, with pointer check: p50 %.3f, p99 %.3f ms (budget 1 ms): %@",
                named.name, path.p50 + pointer.p50, summonP99, summonOK ? "PASS" : "FAIL"))
        passed = passed && summonOK
        return passed
    }

    private static func rows(theme named: NamedTheme, verdicts: inout [String]) async -> Bool {
        let standard = named.name == ThemeStore.standardName
        say("\n## Updating nine changed rows, \(named.name) (apply + draw + commit, n=160, one update every 8 ms)")
        var updateTable = TextTable(["variant", "main-thread CPU min / p50 / p99 ms", "wall min / p50 / p99 ms"])
        let plain = await RowUpdateBench.deterministic(halo: false, theme: named.theme)
        updateTable.add([
            named.theme.light.textHalo == nil ? "no halo" : "its own halo", triple(plain.cpu), triple(plain.wall),
        ])
        if standard {
            let halo = await RowUpdateBench.deterministic(halo: true)
            updateTable.add(["text halo", triple(halo.cpu), triple(halo.wall)])
        }
        say(updateTable.render())
        if standard {
            let cycle = await RowUpdateBench.throughDisplayCycle()
            say(
                "through the display cycle (probe, n=\(cycle.cpu.count)): CPU \(triple(cycle.cpu)), handler to commit \(triple(cycle.commit)), handler to frame target \(triple(cycle.frame))"
            )
        }
        let updateOK = LatencyBudget.rowUpdate.violation(plain.cpu, label: "row update") == nil
        verdicts.append(
            String(
                format: "%@ nine changed rows, main-thread CPU: p50 %.3f, p99 %.3f ms (budget 2 / 4.5 ms): %@",
                named.name, plain.cpu.p50, plain.cpu.p99, updateOK ? "PASS" : "FAIL"))
        return updateOK
    }

    private static func keystroke(passes: Int, lineCache: Bool, theme named: NamedTheme, verdicts: inout [String]) async
        -> Bool
    {
        let cache = lineCache ? "" : ", without the line cache"
        say(
            "\n## A keystroke split into its parts, \(named.name) (main-thread CPU, ms; typed into the field editor\(cache))"
        )
        guard let split = await KeystrokeBench.run(passes: passes, lineCache: lineCache, theme: named.theme) else {
            verdicts.append("keystroke split: no idle moment; not measured: FAIL")
            return false
        }
        var table = TextTable(["part", "n", "min / p50 / p99"])
        for (name, samples) in [
            ("field editor", split.fieldEditor), ("update: filter, apply, selection, action bar", split.update),
            ("list draw", split.listDraw), ("rest of the panel's draw", split.otherDraw),
            ("Core Animation commit", split.commit), ("draw and commit", split.drawAndCommit),
            ("whole keystroke", split.whole),
        ] {
            table.add([name, "\(samples.count)", triple(samples)])
        }
        say(table.render())
        say("longest time on screen in one batch: \(format(split.longestBatch, 2)) s")
        let whole = LatencySummary(split.whole)
        let ok = LatencyBudget.keystroke.violation(whole, label: "keystroke") == nil
        verdicts.append(
            String(
                format:
                    "%@ keystroke typed into the field editor%@, main-thread CPU: p50 %.3f, p99 %.3f ms (budget 3 / 5 ms): %@",
                named.name, cache, whole.p50, whole.p99, ok ? "PASS" : "FAIL"))
        return ok
    }

    private static func motion(themes: [NamedTheme]) async {
        say("\n## Lens glide (main-thread CPU per move, call + commit, ms)")
        let glide = await MotionBench.lensGlide()
        say(glide.map { "\($0.style): \(triple($0.summary))" }.joined(separator: "\n"))

        for named in themes {
            say("\n## Glass height animation, \(named.name) (display link)")
            let height = await MotionBench.heightAnimation(theme: named.theme)
            say(
                String(
                    format:
                        "%d animations, %d ticks, main-thread CPU per tick %.3f ms, longest gap between ticks %.2f ms (refresh %.2f ms)",
                    height.animations, height.ticks, height.cpuPerTick, height.longestGap, height.refresh))
        }
        // Every theme, so the split layout's results container is set against a list that is new
        // in one piece of glass too.
        for named in themes {
            say(
                "\n## First results after a compact summon, \(named.name) (main-thread CPU, content + draw + commit, ms)"
            )
            guard let result = await MotionBench.firstResults(theme: named.theme) else {
                say("no idle moment; not measured")
                continue
            }
            say(
                "first time content shows after the compact look: n=\(result.first.count) \(triple(result.first)); "
                    + "later times: n=\(result.later.count) \(triple(result.later))")
        }
    }

    private static func components(themes: [NamedTheme], verdicts: inout [String]) async -> Bool {
        var passed = true
        say("\n## Components (main-thread CPU, apply + draw + commit, ms)")
        var componentTable = TextTable(["measure", "n", "min / p50 / p99", "budget p50 / p99", "note"])
        var cards: [ComponentBench.Result] = []
        for named in themes {
            let card = await ComponentBench.actionCard(theme: named.theme)
            for result in [card.open, card.filter] {
                cards.append(
                    ComponentBench.Result(
                        label: "\(named.name) \(result.label)", cpu: result.cpu, budget: result.budget,
                        note: result.note))
            }
        }
        let gridResults = [
            await ComponentBench.gridFiltering(atlas: true), await ComponentBench.gridFiltering(atlas: false),
        ]
        for result in gridResults + [await ComponentBench.detailAppend()] + cards {
            componentTable.add([
                result.label, "\(result.cpu.count)", triple(result.cpu),
                "\(format(result.budget.p50, 1)) / \(format(result.budget.p99, 1))", result.note,
            ])
            let ok = result.budget.violation(result.cpu, label: result.label) == nil
            verdicts.append(
                String(
                    format: "%@: p50 %.3f, p99 %.3f ms (budget %.1f / %.1f ms): %@", result.label, result.cpu.p50,
                    result.cpu.p99, result.budget.p50, result.budget.p99, ok ? "PASS" : "FAIL"))
            passed = passed && ok
        }
        say(componentTable.render())
        return passed
    }

    /// Opening the action card, split into the present call, the display and the commit.
    private static func actionCard(verdicts: inout [String]) async -> Bool {
        say("\n## Action card open (main-thread CPU, ms)")
        let card = await ComponentBench.actionCard()
        let split = ComponentBench.lastOpenSplit
        var table = TextTable(["part", "n", "min / p50 / p99"])
        table.add(["present", "\(split.present.count)", triple(split.present)])
        table.add(["display", "\(split.display.count)", triple(split.display)])
        table.add(["commit", "\(split.commit.count)", triple(split.commit)])
        table.add(["whole open", "\(card.open.cpu.count)", triple(card.open.cpu)])
        table.add(["filter keystroke", "\(card.filter.cpu.count)", triple(card.filter.cpu)])
        say(table.render())
        say(card.open.note)
        var passed = true
        for result in [card.open, card.filter] {
            let ok = result.budget.violation(result.cpu, label: result.label) == nil
            verdicts.append(
                String(
                    format: "%@: p50 %.3f, p99 %.3f ms (budget %.1f / %.1f ms): %@", result.label, result.cpu.p50,
                    result.cpu.p99, result.budget.p50, result.budget.p99, ok ? "PASS" : "FAIL"))
            passed = passed && ok
        }
        return passed
    }

    static func measure(_ count: Int, warmUp: Int = 20, _ body: () -> Void) -> LatencySummary {
        var samples: [Double] = []
        for step in 0..<(count + warmUp) {
            let start = LatencyClock.now()
            body()
            if step >= warmUp { samples.append(LatencyClock.ms(start, LatencyClock.now())) }
        }
        return LatencySummary(samples)
    }

    static func pair(_ samples: [Double]) -> String {
        let summary = LatencySummary(samples)
        return summary.count == 0 ? "-" : "\(format(summary.p50)) / \(format(summary.p99))"
    }

    static func triple(_ samples: [Double]) -> String { triple(LatencySummary(samples)) }

    static func triple(_ summary: LatencySummary) -> String {
        "\(format(summary.min, 3)) / \(format(summary.p50, 3)) / \(format(summary.p99, 3))"
    }
}
