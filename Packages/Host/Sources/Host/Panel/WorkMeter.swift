import LauncherUI

/// Splits an interaction's main-thread CPU time between the host and the code it calls: Root's
/// query and LauncherUI's drawing. Budget tests and benches turn it on to measure the host's own
/// work; otherwise every call is a plain pass-through.
///
/// Fuzzy index searches have a bucket of their own, ``searchNanoseconds``, because a grid's budget
/// counts LauncherUI's apply but not the engine's matching.
@MainActor public final class WorkMeter {
    /// False makes ``measure(_:)`` call straight through.
    public var isEnabled = false
    /// CPU nanoseconds spent inside measured calls since the last ``reset()``.
    public private(set) var calledNanoseconds: UInt64 = 0
    /// CPU nanoseconds spent inside fuzzy index searches since the last ``reset()``.
    public private(set) var searchNanoseconds: UInt64 = 0

    public init() {}

    /// Runs `body` and, when on, adds its thread CPU time to ``calledNanoseconds``.
    @inline(__always)
    public func measure<Result>(_ body: () -> Result) -> Result {
        guard isEnabled else { return body() }
        let start = LatencyClock.threadCPUNanoseconds()
        let result = body()
        calledNanoseconds &+= LatencyClock.threadCPUNanoseconds() &- start
        return result
    }

    /// Runs a fuzzy index search and, when on, adds its thread CPU time to ``searchNanoseconds``.
    @inline(__always)
    public func measureSearch<Result>(_ body: () -> Result) -> Result {
        guard isEnabled else { return body() }
        let start = LatencyClock.threadCPUNanoseconds()
        let result = body()
        searchNanoseconds &+= LatencyClock.threadCPUNanoseconds() &- start
        return result
    }

    public func reset() {
        calledNanoseconds = 0
        searchNanoseconds = 0
    }
}
