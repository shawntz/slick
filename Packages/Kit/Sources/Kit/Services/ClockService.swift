import Foundation

/// The current time, the user's calendar and waiting. Features read time only from here, so tests
/// can fix it and move it forward.
public protocol ClockService: Sendable {
    var now: Date { get }
    var timeZone: TimeZone { get }
    var locale: Locale { get }
    /// A Gregorian calendar in ``timeZone`` and ``locale``.
    var calendar: Calendar { get }

    /// Waits for the duration. Throws `CancellationError` when the task is cancelled.
    func sleep(for duration: Duration) async throws
}

/// The real clock. It has no side effects, so it lives in Kit and every environment uses it.
public struct SystemClock: ClockService {
    public init() {}

    public var now: Date { Date() }
    public var timeZone: TimeZone { .current }
    public var locale: Locale { .current }

    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        return calendar
    }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
