import Foundation
import Synchronization

/// Power requests that only get recorded, for scenarios, self-tests and tests. Nothing sleeps, locks
/// or logs out.
nonisolated final class SimulatedPower: PowerService {
    private struct State {
        var requests: [PowerRequest] = []
        var failures: [PowerRequest: SystemFailure] = [:]
    }

    private let state = Mutex(State())

    init() {}

    /// Every request that succeeded, in order.
    var requests: [PowerRequest] { state.withLock { $0.requests } }

    /// Makes a request fail from now on, as on a Mac that cannot do it.
    func fail(_ request: PowerRequest, with failure: SystemFailure) {
        state.withLock { $0.failures[request] = failure }
    }

    /// A request set to fail as unavailable fails here too, as the live check does.
    func checkAvailable(_ request: PowerRequest) async throws {
        try state.withLock { state in
            if state.failures[request] == .unavailable { throw SystemFailure.unavailable }
        }
    }

    func perform(_ request: PowerRequest) async throws {
        try state.withLock { state in
            if let failure = state.failures[request] { throw failure }
            state.requests.append(request)
        }
    }
}
