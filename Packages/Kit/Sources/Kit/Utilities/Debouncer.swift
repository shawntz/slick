/// Runs work after input has been quiet for a while, cancelling work that is still waiting when new
/// input arrives. For example, saving a draft 300 ms after the last keystroke.
///
/// Each ``schedule(_:)`` replaces the pending work. Work that already started is not interrupted;
/// check `Task.isCancelled` inside long work if a newer call should stop it.
@MainActor public final class Debouncer {
    private let delay: Duration
    private let clock: any ClockService
    private var pending: Task<Void, Never>?
    private var generation = 0

    /// - Parameters:
    ///   - delay: How long input must be quiet before the work runs.
    ///   - clock: The clock to wait on. Pass the feature's clock so tests can move time forward.
    public init(delay: Duration, clock: any ClockService = SystemClock()) {
        self.delay = delay
        self.clock = clock
    }

    /// Runs the work after the delay, unless another call comes first.
    public func schedule(_ work: @escaping @MainActor @Sendable () async -> Void) {
        pending?.cancel()
        generation += 1
        let current = generation
        let clock = clock
        let delay = delay
        pending = Task { [weak self] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await work()
            if let self, self.generation == current {
                self.pending = nil
            }
        }
    }

    /// Drops the pending work.
    public func cancel() {
        pending?.cancel()
        pending = nil
    }

    /// True from ``schedule(_:)`` until the work has finished or was cancelled.
    public var isPending: Bool {
        pending != nil
    }
}
