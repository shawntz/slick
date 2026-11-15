import Foundation

/// Suspends until the latency probe reports a record, or a timeout passes, without waking the
/// main thread in between. Polling would add its own wake-ups to the CPU time being measured.
final class RecordWaiter {
    private var continuation: CheckedContinuation<Void, Never>?

    /// Waits for `resume()` or `timeout` seconds, whichever comes first.
    func wait(timeout: Double) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated { self?.resume() }
            }
        }
    }

    /// Ends the current wait, if there is one.
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
