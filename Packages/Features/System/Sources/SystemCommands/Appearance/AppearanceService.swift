import Foundation
import Kit
import Synchronization

/// The system's light or dark appearance.
///
/// The live implementation changes how every app on the Mac looks. Tests, scenarios, self-tests and
/// benchmarks get ``SimulatedAppearance``.
nonisolated protocol AppearanceService: Sendable {
    /// Switches between light and dark and returns the new state: true for dark.
    @concurrent func toggleDarkMode() async throws -> Bool
}

/// The appearance service for each kind of run.
nonisolated enum AppearanceServiceKey: FeatureServiceKey {
    static func live(_ context: FeatureContext) -> any AppearanceService {
        LiveAppearance()
    }

    static func isolated(_ context: FeatureContext) -> any AppearanceService {
        SimulatedAppearance()
    }
}

/// An appearance that exists only in memory.
nonisolated final class SimulatedAppearance: AppearanceService {
    private struct State {
        var isDark: Bool
        var failure: SystemFailure?
        var failsOnce = false
    }

    private let state: Mutex<State>

    init(isDark: Bool = false) {
        state = Mutex(State(isDark: isDark))
    }

    var isDark: Bool { state.withLock { $0.isDark } }

    /// Makes toggles fail, such as when the permission is missing: every toggle, or only the next.
    func fail(with failure: SystemFailure?, once: Bool = false) {
        state.withLock { state in
            state.failure = failure
            state.failsOnce = once
        }
    }

    func toggleDarkMode() async throws -> Bool {
        try state.withLock { state in
            if let failure = state.failure {
                if state.failsOnce { state.failure = nil }
                throw failure
            }
            state.isDark.toggle()
            return state.isDark
        }
    }
}
