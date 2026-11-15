import Foundation
import Kit

/// The live clock. Unlike Kit's `SystemClock`, its time zone and locale follow the user's changes
/// while the app runs, because they are the auto-updating values.
nonisolated public struct LiveClock: ClockService {
    public init() {}

    public var now: Date { Date() }
    public var timeZone: TimeZone { .autoupdatingCurrent }
    public var locale: Locale { .autoupdatingCurrent }

    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        return calendar
    }

    /// Waits on the continuous clock, which keeps counting while the Mac sleeps.
    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
