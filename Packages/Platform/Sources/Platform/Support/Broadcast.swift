import Synchronization

/// Hands each value to every stream made from it. Services use it for their change streams.
///
/// A stream ends when its consuming task is cancelled or the stream is dropped, and then it stops
/// listening. Sending never waits: each stream buffers what its consumer has not read yet.
nonisolated final class Broadcast<Element: Sendable>: Sendable {
    private struct State {
        var sinks: [Int: @Sendable (Element) -> Void] = [:]
        var nextID = 0
    }

    private let state = Mutex(State())

    init() {}

    /// A stream of the values `transform` maps to non-nil, from now on. `onEnd` runs once when the
    /// stream ends.
    func stream<Output: Sendable>(
        onEnd: (@Sendable () -> Void)? = nil,
        _ transform: @escaping @Sendable (Element) -> Output?
    ) -> AsyncStream<Output> {
        let (stream, continuation) = AsyncStream.makeStream(of: Output.self)
        let id = subscribe { element in
            if let output = transform(element) { continuation.yield(output) }
        }
        continuation.onTermination = { [weak self] _ in
            self?.unsubscribe(id)
            onEnd?()
        }
        return stream
    }

    /// A stream of every value from now on.
    func stream() -> AsyncStream<Element> {
        stream { $0 }
    }

    /// Calls `sink` with every value from now on, on the sender's thread, until ``unsubscribe(_:)``.
    func subscribe(_ sink: @escaping @Sendable (Element) -> Void) -> Int {
        state.withLock { state in
            state.nextID += 1
            state.sinks[state.nextID] = sink
            return state.nextID
        }
    }

    func unsubscribe(_ id: Int) {
        _ = state.withLock { $0.sinks.removeValue(forKey: id) }
    }

    /// Hands the value to every listener. Returns at once.
    func send(_ element: Element) {
        let sinks = state.withLock { Array($0.sinks.values) }
        for sink in sinks {
            sink(element)
        }
    }

    /// How many listeners there are.
    var listenerCount: Int {
        state.withLock { $0.sinks.count }
    }
}
