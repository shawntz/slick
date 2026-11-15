import Foundation
import Kit

/// The user's region and time zone, which decide how numbers, dates and times read.
nonisolated struct RegionSnapshot: Hashable, Sendable {
    var locale: Locale
    var timeZone: TimeZone
}

/// Where the region comes from, and when it changes. The calculator reads it when the feature
/// starts and again after each change, never per keystroke.
nonisolated protocol RegionService: Sendable {
    /// The region now.
    var current: RegionSnapshot { get }

    /// Yields once each time the user changes the region, the formats or the time zone, or the Mac
    /// moves to another zone. Each call returns its own stream; it ends when the consuming task is
    /// cancelled.
    func changes() -> AsyncStream<Void>
}

/// The region service for each kind of run.
nonisolated enum RegionServiceKey: FeatureServiceKey {
    static func live(_ context: FeatureContext) -> any RegionService {
        SystemRegion()
    }

    static func isolated(_ context: FeatureContext) -> any RegionService {
        FixedRegion(RegionSnapshot(locale: context.clock.locale, timeZone: context.clock.timeZone))
    }
}

/// The Mac's own region. It reads the locale and time zone that follow System Settings, and listens
/// for Foundation's notifications that either changed. Reading them needs no permission and shows
/// nothing.
nonisolated final class SystemRegion: RegionService {
    var current: RegionSnapshot {
        RegionSnapshot(locale: .autoupdatingCurrent, timeZone: .autoupdatingCurrent)
    }

    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let center = NotificationCenter.default
        let observers = Observers(
            [NSLocale.currentLocaleDidChangeNotification, .NSSystemTimeZoneDidChange].map { name in
                center.addObserver(forName: name, object: nil, queue: nil) { _ in continuation.yield() }
            })
        continuation.onTermination = { _ in observers.remove(from: center) }
        return stream
    }

    /// Notification observer tokens, removed once when the stream ends.
    private final class Observers: @unchecked Sendable {
        private let tokens: [any NSObjectProtocol]

        init(_ tokens: [any NSObjectProtocol]) {
            self.tokens = tokens
        }

        func remove(from center: NotificationCenter) {
            for token in tokens {
                center.removeObserver(token)
            }
        }
    }
}

/// A region that never changes, for scenarios, self-tests and benchmarks: the run's clock's locale
/// and time zone.
nonisolated final class FixedRegion: RegionService {
    let current: RegionSnapshot

    init(_ snapshot: RegionSnapshot) {
        current = snapshot
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}
