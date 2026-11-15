import Darwin

/// One timebase for latency math: mach absolute time.
///
/// It costs about 4 ns to read. `NSEvent.timestamp`, Carbon event times, `CACurrentMediaTime`,
/// `CADisplayLink` timestamps and ScreenCaptureKit display times all count on this same clock, so
/// they subtract directly. `ContinuousClock` costs about seven times more and counts sleep.
nonisolated public enum LatencyClock {
    /// Ticks per nanosecond, as numerator and denominator.
    public static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// The current time in mach ticks.
    @inline(__always) public static func now() -> UInt64 { mach_absolute_time() }

    @inline(__always) public static func nanoseconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
    }

    /// Signed milliseconds from `start` to `end`, both in mach ticks.
    @inline(__always) public static func ms(_ start: UInt64, _ end: UInt64) -> Double {
        end >= start ? nanoseconds(end - start) / 1e6 : -nanoseconds(start - end) / 1e6
    }

    /// Mach ticks for a seconds-of-uptime timestamp such as `NSEvent.timestamp`.
    @inline(__always) public static func ticks(seconds: Double) -> UInt64 {
        UInt64(max(0, seconds) * 1e9 * Double(timebase.denom) / Double(timebase.numer))
    }

    /// CPU time the calling thread has used, in nanoseconds. It is a system call (about 0.1 µs).
    @inline(__always) public static func threadCPUNanoseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    }
}
