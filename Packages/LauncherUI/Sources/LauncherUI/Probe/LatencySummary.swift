import Foundation

/// Order statistics of a set of latency samples, with nearest-rank percentiles.
nonisolated public struct LatencySummary: Sendable, CustomStringConvertible {
    public let count: Int
    public let min: Double
    public let p50: Double
    public let p90: Double
    public let p99: Double
    public let max: Double

    public init(_ samples: [Double]) {
        let sorted = samples.filter(\.isFinite).sorted()
        count = sorted.count
        func rank(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return .nan }
            let index = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
            return sorted[Swift.min(Swift.max(index, 0), sorted.count - 1)]
        }
        min = sorted.first ?? .nan
        max = sorted.last ?? .nan
        p50 = rank(0.5)
        p90 = rank(0.9)
        p99 = rank(0.99)
    }

    public var description: String {
        String(format: "n=%d min=%.3f p50=%.3f p90=%.3f p99=%.3f max=%.3f", count, min, p50, p90, p99, max)
    }
}

/// A main-thread time budget at two percentiles, in milliseconds.
nonisolated public struct LatencyBudget: Sendable {
    public var p50: Double
    public var p99: Double

    public init(p50: Double, p99: Double) {
        self.p50 = p50
        self.p99 = p99
    }

    /// Updating nine changed rows: draw and commit included.
    public static let rowUpdate = LatencyBudget(p50: 2, p99: 4.5)
    /// The summon path, excluding `makeKey`, which is window-server time.
    public static let summon = LatencyBudget(p50: 1, p99: 1)
    /// All main-thread work for one keystroke, from docs/ARCHITECTURE.md.
    public static let keystroke = LatencyBudget(p50: 3, p99: 5)

    /// A sentence describing the overrun, or nil when `summary` is within budget. `scale` relaxes
    /// the budget for slower machines.
    public func violation(_ summary: LatencySummary, label: String, scale: Double = 1) -> String? {
        guard summary.p50 > p50 * scale || summary.p99 > p99 * scale else { return nil }
        return String(
            format: "%@ over budget: p50 %.3f ms (budget %.3f), p99 %.3f ms (budget %.3f), n=%d",
            label, summary.p50, p50 * scale, summary.p99, p99 * scale, summary.count
        )
    }

    /// The scale factor from `LATENCY_BUDGET_SCALE`, or 1. CI machines set it to relax budgets.
    public static var environmentScale: Double {
        ProcessInfo.processInfo.environment["LATENCY_BUDGET_SCALE"].flatMap(Double.init) ?? 1
    }
}
