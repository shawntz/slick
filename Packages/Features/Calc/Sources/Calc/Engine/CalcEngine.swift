import CoreBridge
import Foundation
import Kit
import os

/// The feature's one calculator, and what it needs before it can answer: the engine's lookup
/// tables, the time zone rules and the context built from the region and settings.
///
/// The heavy parts run off the main thread: `Calculator.prepare()` builds tables in about 0.7 ms,
/// and the zone rules read about 260 small system files. Attaching them is a pointer swap, done on
/// the main actor, so the keystroke path never waits on the calculator's lock.
final class CalcEngine {
    /// Nil when the Rust core could not be loaded, such as after an ABI mismatch. The feature then
    /// answers nothing.
    let calculator: Calculator?
    /// True once tables, zones and the context are in place. Until then the provider answers
    /// nothing, so the first keystroke never pays for preparing.
    private(set) var isReady = false
    /// The context the calculator uses now, for formatting the feature does itself.
    private(set) var context = CalculatorContext()

    private let region: any RegionService
    private let settings: FeatureSettings
    private let clock: any ClockService
    private let log: Logger
    /// The local zone the attached zone rules were loaded with.
    private var zonesLoadedFor: String?
    /// Counts refreshes, so one that finishes after a newer one does not undo it.
    private var generation = 0
    /// How many refreshes have finished, and who waits for a count. For tests.
    private(set) var finishedRefreshes = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(context: FeatureContext, region: any RegionService) {
        let log = context.log
        do {
            calculator = try Calculator()
        } catch {
            log.error("The calculator engine could not load: \(String(describing: error), privacy: .public)")
            calculator = nil
        }
        self.region = region
        self.settings = context.settings
        self.clock = context.clock
        self.log = log
    }

    /// Reads the region and settings again and applies them. Called at activation, when a format
    /// setting changes and when the region changes.
    func refresh() async {
        defer { finishRefresh() }
        guard let calculator else { return }
        generation += 1
        let mine = generation
        let snapshot = region.current
        let zone = snapshot.timeZone.identifier
        let prepared = await Self.prepare(
            region: snapshot, choices: FormatChoices(settings), now: clock.now,
            loadZonesFor: zonesLoadedFor == zone ? nil : zone)
        // A newer refresh started meanwhile, such as after a second zone change. Its zones and
        // context win; attaching these would pair the old zone's rules with the new context.
        guard mine == generation else { return }
        if let zones = prepared.zones {
            calculator.setTimeZones(zones)
            zonesLoadedFor = zone
        }
        apply(prepared.context, to: calculator)
        isReady = true
    }

    /// Waits until `count` refreshes have finished.
    func waitForRefreshes(_ count: Int) async {
        guard finishedRefreshes < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    private func finishRefresh() {
        finishedRefreshes += 1
        let due = waiters.filter { $0.count <= finishedRefreshes }
        waiters.removeAll { $0.count <= finishedRefreshes }
        for waiter in due { waiter.continuation.resume() }
    }

    /// Sets the context, falling back to no grouping and then to the engine's defaults when the
    /// engine refuses a separator.
    private func apply(_ wanted: CalculatorContext, to calculator: Calculator) {
        var candidates = [wanted]
        var ungrouped = wanted
        ungrouped.groupingSeparator = nil
        candidates.append(ungrouped)
        candidates.append(CalculatorContext(localZone: wanted.localZone, localOffsetSeconds: wanted.localOffsetSeconds))
        for candidate in candidates {
            do {
                try calculator.setContext(candidate)
                context = candidate
                return
            } catch {
                log.error("The calculator refused a context: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private struct Prepared: Sendable {
        let context: CalculatorContext
        let zones: CalculatorTimeZones?
    }

    @concurrent private static func prepare(
        region: RegionSnapshot, choices: FormatChoices, now: Date, loadZonesFor zone: String?
    ) async -> Prepared {
        Calculator.prepare()
        let zones = zone.flatMap { try? CalculatorTimeZones(extraZones: [$0]) }
        return Prepared(context: CalcContextBuilder.context(region: region, choices: choices, now: now), zones: zones)
    }
}
