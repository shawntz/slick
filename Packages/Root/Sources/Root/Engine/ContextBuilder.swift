import CoreBridge
import Foundation
import Kit
import KitHosting

/// Turns the Mac's state, the time and the last run into the engine's context.
nonisolated enum ContextBuilder {
    /// The last item the user ran and when.
    struct LastRun: Sendable {
        var key: UInt64
        var at: Date
    }

    /// The context at `now`. Reads the calendar, which is slow enough to keep off the main thread.
    static func make(
        system: SystemContext, now: Date, calendar: Calendar, lastRun: LastRun?, sessionStart: Bool
    ) -> EngineContext {
        let parts = calendar.dateComponents([.hour, .weekday], from: now)
        // The calendar counts weekdays from Sunday as 1; the engine counts from Monday as 0.
        let weekday = ((parts.weekday ?? 2) + 5) % 7
        let frontmost = system.frontmostBundleID.map {
            ItemKey(rawValue: ItemID(ItemID.ReservedNamespace.app, $0).engineKey)
        }
        return EngineContext(
            now: now.timeIntervalSince1970,
            hour: UInt8(clamping: parts.hour ?? 0),
            weekday: UInt8(clamping: weekday),
            frontmost: frontmost,
            previous: lastRun.map { ItemKey(rawValue: $0.key) },
            sincePrevious: lastRun.map { max(0, now.timeIntervalSince($0.at)) } ?? 0,
            onBattery: system.onBattery,
            displayCount: UInt8(clamping: max(system.displayCount, 1)),
            audioRoute: audioRoute(system.audioRoute),
            sessionStart: sessionStart,
            focus: system.isFocusOn)
    }

    static func audioRoute(_ route: SystemContext.AudioRoute) -> CoreBridge.AudioRoute {
        switch route {
        case .builtIn, .unknown: .builtIn
        case .headphones: .headphones
        case .bluetooth: .bluetooth
        case .external: .other
        }
    }

    /// The wait until the next full hour, when the hour bucket of the context changes.
    static func untilNextHour(after now: Date, calendar: Calendar) -> Duration {
        let next =
            calendar.nextDate(after: now, matching: DateComponents(minute: 0, second: 0), matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(3_600)
        return .seconds(max(1, next.timeIntervalSince(now)))
    }
}
