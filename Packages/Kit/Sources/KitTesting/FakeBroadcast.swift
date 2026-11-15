import Synchronization

/// Delivers values from a fake to every stream made from it, and knows when each consumer has
/// finished with what it received: a consumer is done with a value when it asks for the next one.
/// That is what lets ``FakeServices/settle()`` wait for a feature's background loops.
///
/// Package access, so the fakes in KitHostingTesting share it. Features cannot see it.
package final class FakeBroadcast<Element: Sendable>: Sendable {
    private struct Listener {
        let accepts: @Sendable (Element) -> Bool
        var queue: [Element] = []
        var waiting: CheckedContinuation<Element?, Never>?
        /// Holds a value it received and has not asked for the next one yet.
        var isBusy = false

        var isIdle: Bool { !isBusy && queue.isEmpty }
    }

    private struct State {
        var listeners: [Int: Listener] = [:]
        var nextID = 0
        var idleWaiters: [CheckedContinuation<Void, Never>] = []

        var isIdle: Bool { listeners.values.allSatisfy(\.isIdle) }

        /// The waiters to resume when every listener is idle.
        mutating func takeIdleWaiters() -> [CheckedContinuation<Void, Never>] {
            guard isIdle else { return [] }
            defer { idleWaiters = [] }
            return idleWaiters
        }
    }

    private let state = Mutex(State())

    package init() {}

    /// A stream of the values `transform` maps to non-nil, from now on. It ends when the consuming
    /// task is cancelled, and then calls `onEnd`.
    package func stream<Output: Sendable>(
        onEnd: (@Sendable () -> Void)? = nil, _ transform: @escaping @Sendable (Element) -> Output?
    ) -> AsyncStream<Output> {
        let id = state.withLock { state in
            state.nextID += 1
            state.listeners[state.nextID] = Listener(accepts: { transform($0) != nil })
            return state.nextID
        }
        return AsyncStream(
            unfolding: { [self] in await next(for: id).flatMap(transform) },
            onCancel: { [self] in
                remove(id)
                onEnd?()
            })
    }

    /// A stream of every value.
    package func stream() -> AsyncStream<Element> {
        stream { $0 }
    }

    /// Hands the value to every listener that accepts it. Returns at once.
    package func send(_ element: Element) {
        let resumptions = state.withLock { state -> [CheckedContinuation<Element?, Never>] in
            var resumptions: [CheckedContinuation<Element?, Never>] = []
            for id in state.listeners.keys {
                guard var listener = state.listeners[id], listener.accepts(element) else { continue }
                if let waiting = listener.waiting {
                    listener.waiting = nil
                    listener.isBusy = true
                    resumptions.append(waiting)
                } else {
                    listener.queue.append(element)
                }
                state.listeners[id] = listener
            }
            return resumptions
        }
        for continuation in resumptions {
            continuation.resume(returning: element)
        }
    }

    /// Returns once every listener has asked for a value after the last one it received, or ended.
    package func waitUntilIdle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isIdle = state.withLock { state in
                if state.isIdle { return true }
                state.idleWaiters.append(continuation)
                return false
            }
            if isIdle { continuation.resume() }
        }
    }

    /// True when no listener holds an unfinished value.
    package var isIdle: Bool { state.withLock(\.isIdle) }

    /// How many streams are listening.
    package var listenerCount: Int { state.withLock { $0.listeners.count } }

    /// What a consumer asking for its next value gets.
    private enum Step {
        case deliver(Element?)
        case wait
    }

    private func next(for id: Int) async -> Element? {
        let (step, idle) = state.withLock { state -> (Step, [CheckedContinuation<Void, Never>]) in
            guard var listener = state.listeners[id] else { return (.deliver(nil), state.takeIdleWaiters()) }
            listener.isBusy = false
            if !listener.queue.isEmpty {
                listener.isBusy = true
                let element = listener.queue.removeFirst()
                state.listeners[id] = listener
                return (.deliver(element), [])
            }
            state.listeners[id] = listener
            return (.wait, state.takeIdleWaiters())
        }
        for waiter in idle { waiter.resume() }
        if case .deliver(let element) = step { return element }
        return await withCheckedContinuation { continuation in
            let immediate = state.withLock { state -> Step in
                guard var listener = state.listeners[id] else { return .deliver(nil) }
                if !listener.queue.isEmpty {
                    listener.isBusy = true
                    let element = listener.queue.removeFirst()
                    state.listeners[id] = listener
                    return .deliver(element)
                }
                listener.waiting = continuation
                state.listeners[id] = listener
                return .wait
            }
            if case .deliver(let element) = immediate { continuation.resume(returning: element) }
        }
    }

    private func remove(_ id: Int) {
        let (waiting, idle) = state.withLock { state in
            let listener = state.listeners.removeValue(forKey: id)
            return (listener?.waiting, state.takeIdleWaiters())
        }
        waiting?.resume(returning: nil)
        for waiter in idle { waiter.resume() }
    }
}
