import Foundation
import IOKit

/// Keeps on-screen work away from the person at the keyboard. A capture or a clip takes key
/// status, which would swallow their typing, so it starts only after the Mac has been idle for a
/// while and stops the moment they touch the keyboard or mouse.
///
/// It reads `HIDIdleTime` from `IOHIDSystem`, the value `ioreg -c IOHIDSystem` prints: the time
/// since the last real keyboard, mouse or trackpad input. This process's own windows taking key
/// status, and events sent to them in process, do not reset it. Reading it needs no permission.
nonisolated public enum IdleGuard {
    /// Seconds since the last keyboard or mouse input, or nil when the value cannot be read.
    public static func idleSeconds() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard
            let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()
        else { return nil }
        if let number = value as? NSNumber { return number.doubleValue / 1_000_000_000 }
        if let data = value as? Data, data.count >= 8 {
            let nanoseconds = data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            return Double(nanoseconds) / 1_000_000_000
        }
        return nil
    }

    /// Why waiting ended without an idle moment.
    public enum WaitFailure: Error, Sendable, Equatable {
        /// `HIDIdleTime` could not be read, so idleness cannot be shown.
        case unreadable
        /// No idle moment came before the deadline.
        case deadline
    }

    /// Returns once the Mac has been idle for `seconds`, checking every `interval` seconds, or
    /// throws when `deadline` passes first. `report` hears the idle time the first time it waits.
    public static func wait(
        seconds: Double, interval: Double = 3, until deadline: Date, report: ((Double) -> Void)? = nil
    ) async throws(WaitFailure) {
        var reported = false
        while Date() < deadline {
            guard let idle = idleSeconds() else { throw .unreadable }
            if idle >= seconds { return }
            if !reported {
                report?(idle)
                reported = true
            }
            // Sleep only as long as the idle time could still need, or the interval.
            let wait = min(interval, max(0.2, seconds - idle))
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
        throw .deadline
    }

    /// Watches for input while something is on screen. Start it right before the work and read
    /// `inputArrived` after, or pass `onInput` to stop at once.
    ///
    /// It polls `HIDIdleTime` every `interval` seconds on the main run loop. Input shows as the
    /// idle time going down: it only grows while nobody touches the Mac.
    @MainActor
    public final class Watch {
        /// Whether input arrived since `start()`.
        public private(set) var inputArrived = false
        /// Called once, on the main actor, when input first arrives.
        public var onInput: (() -> Void)?
        private let interval: Double
        private let idleSource: () -> Double?
        private var timer: Timer?
        private var lastIdle: Double = 0

        /// A watch that polls every `interval` seconds. `idleSource` stands in for `HIDIdleTime`
        /// in tests.
        public init(interval: Double = 0.05, idleSource: @escaping () -> Double? = IdleGuard.idleSeconds) {
            self.interval = interval
            self.idleSource = idleSource
        }

        public func start() {
            inputArrived = false
            lastIdle = idleSource() ?? 0
            timer?.invalidate()
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        public func stop() {
            check()
            timer?.invalidate()
            timer = nil
        }

        /// Reads the idle time now. Called by the timer, and once more by `stop()`.
        public func check() {
            guard !inputArrived else { return }
            guard let idle = idleSource() else { return }
            if idle + 0.001 < lastIdle {
                inputArrived = true
                onInput?()
            }
            lastIdle = idle
        }
    }
}
