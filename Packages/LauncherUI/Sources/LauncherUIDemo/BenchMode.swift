import AppKit
import LauncherUI
import LauncherUITesting

/// Prints the latency tables and checks the budgets, measured inside an app bundle:
/// summon strategies (with key status, against ScreenCaptureKit display times), updating nine
/// changed rows, the lens glide and the glass height animation.
///
/// Batches keep the panel on screen under two seconds, and each summon holds key status for
/// about 120 ms.
enum BenchMode {
    static func run(_ options: DemoOptions) async -> Bool {
        let cycles = options.int("summons", 18)
        var verdicts: [String] = []
        var passed = true

        say("## Summon (key status, n=\(cycles) per row; times from the trigger, ms)")
        var summonTable = TextTable([
            "strategy", "ramp", "path excl. makeKey p50/p99", "makeKey p50/p99", "first pixels p50/p99",
            "key look p50/p99", "frames 1-5, share of the key look",
        ])
        var paths: [Double] = []  // the default strategy's, which the budget covers
        for (strategy, ramp) in [
            (SummonStrategy.layerOpacity, 0), (.layerOpacity, 2), (.layerOpacity, 3), (.orderFront, 0),
        ] {
            let result = await SummonBench.run(strategy: strategy, rampFrames: ramp, cycles: cycles)
            if strategy == .layerOpacity && ramp == Theme.standard.motion.summonRampFrames { paths = result.paths }
            let trajectory = SummonBench.medianTrajectory(result.trajectories).map { format($0) }.joined(separator: " ")
            summonTable.add([
                strategy.rawValue, "\(ramp)", pair(result.paths), pair(result.makeKey), pair(result.firstPixels),
                pair(result.keyLook), trajectory,
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
                    "summon path (default strategy) excluding makeKey, with pointer check: p50 %.3f, p99 %.3f ms (budget 1 ms): %@",
                path.p50 + pointer.p50, summonP99, summonOK ? "PASS" : "FAIL"))
        passed = passed && summonOK

        say("\n## Updating nine changed rows (apply + draw + commit, n=160, one update every 8 ms)")
        var updateTable = TextTable(["variant", "main-thread CPU min / p50 / p99 ms", "wall min / p50 / p99 ms"])
        let plain = await RowUpdateBench.deterministic(halo: false)
        let halo = await RowUpdateBench.deterministic(halo: true)
        updateTable.add(["no halo", triple(plain.cpu), triple(plain.wall)])
        updateTable.add(["text halo", triple(halo.cpu), triple(halo.wall)])
        say(updateTable.render())
        let cycle = await RowUpdateBench.throughDisplayCycle()
        say(
            "through the display cycle (probe, n=\(cycle.cpu.count)): CPU \(triple(cycle.cpu)), handler to commit \(triple(cycle.commit)), handler to frame target \(triple(cycle.frame))"
        )
        let updateOK = LatencyBudget.rowUpdate.violation(plain.cpu, label: "row update") == nil
        verdicts.append(
            String(
                format: "nine changed rows, main-thread CPU: p50 %.3f, p99 %.3f ms (budget 2 / 4.5 ms): %@",
                plain.cpu.p50, plain.cpu.p99, updateOK ? "PASS" : "FAIL"))
        passed = passed && updateOK

        say("\n## Lens glide (main-thread CPU per move, call + commit, ms)")
        let glide = await MotionBench.lensGlide()
        say(glide.map { "\($0.style): \(triple($0.summary))" }.joined(separator: "\n"))

        say("\n## Glass height animation (display link)")
        let height = await MotionBench.heightAnimation()
        say(
            String(
                format:
                    "%d animations, %d ticks, main-thread CPU per tick %.3f ms, longest gap between ticks %.2f ms (refresh %.2f ms)",
                height.animations, height.ticks, height.cpuPerTick, height.longestGap, height.refresh))

        say("\n## Components (main-thread CPU, apply + draw + commit, ms)")
        var componentTable = TextTable(["measure", "n", "min / p50 / p99", "budget p50 / p99", "note"])
        let card = await ComponentBench.actionCard()
        let gridResults = [
            await ComponentBench.gridFiltering(atlas: true), await ComponentBench.gridFiltering(atlas: false),
        ]
        for result in gridResults + [await ComponentBench.detailAppend(), card.open, card.filter] {
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

        say("\n## Budgets")
        for verdict in verdicts { say(verdict) }
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
