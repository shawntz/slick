import Kit

/// One power or session request.
nonisolated enum PowerRequest: String, Hashable, Sendable, CaseIterable {
    case sleep
    case sleepDisplays
    case lockScreen
    case startScreenSaver
    case logOut
    case restart
    case shutDown
}

/// Sleeping the Mac and its displays, locking the screen, the screen saver, and ending the session.
///
/// The live implementation acts on the real Mac: it can put it to sleep or log the user out. Tests,
/// scenarios, self-tests and benchmarks get ``SimulatedPower``, which only records what was asked.
nonisolated protocol PowerService: Sendable {
    /// Does it. Returns once the system has accepted the request, which for sleep and the session
    /// requests is before the Mac acts on it. Throws ``SystemFailure``.
    @concurrent func perform(_ request: PowerRequest) async throws

    /// Throws ``SystemFailure/unavailable`` when this Mac cannot do the request at all, without
    /// doing it, so the command can say so while the panel is still open. Most requests can only
    /// find out by trying, and pass.
    @concurrent func checkAvailable(_ request: PowerRequest) async throws
}

/// The power service for each kind of run.
nonisolated enum PowerServiceKey: FeatureServiceKey {
    static func live(_ context: FeatureContext) -> any PowerService {
        LivePower(processes: context.processes)
    }

    static func isolated(_ context: FeatureContext) -> any PowerService {
        SimulatedPower()
    }
}
