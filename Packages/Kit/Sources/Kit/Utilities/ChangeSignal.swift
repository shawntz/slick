import Synchronization

/// A signal that something changed, for a host to reload what it shows.
///
/// A source exposes one and calls ``send()`` from any thread when its data changes; the host listens
/// while the page or result is visible and loads again. Send it instead of calling
/// ``ActionContext/reload()`` when the change comes from the data, so the page loads once. Signals
/// coalesce: if several arrive before a listener wakes, it sees one.
public final class ChangeSignal: Sendable {
    private let listeners = Mutex<[Int: AsyncStream<Void>.Continuation]>([:])
    private let nextID = Atomic<Int>(0)
    private let sends = Atomic<Int>(0)

    public init() {}

    /// Tells every listener that something changed.
    public func send() {
        sends.add(1, ordering: .sequentiallyConsistent)
        let current = listeners.withLock { Array($0.values) }
        for listener in current {
            listener.yield()
        }
    }

    /// A stream that yields once per change, from now on. It ends when the consuming task is
    /// cancelled.
    public func stream() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = nextID.add(1, ordering: .relaxed).newValue
        listeners.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.listeners.withLock { $0.removeValue(forKey: id) }
        }
        return stream
    }

    /// How many times the signal was sent. A host compares it with the value at its last load to
    /// tell whether it missed a change.
    public var generation: Int {
        sends.load(ordering: .sequentiallyConsistent)
    }

    /// How many streams are listening. For tests.
    public var listenerCount: Int {
        listeners.withLock { $0.count }
    }
}
