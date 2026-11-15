/// Where the app is running, which decides whether services touch the real Mac.
public enum RunEnvironment: String, Hashable, Sendable, CaseIterable {
    /// The launcher a person uses. Services are real.
    case live
    /// A scripted UI run from a scenario file. Side effects go to fakes.
    case scenario
    /// Start, exercise every feature's registration, exit. Side effects go to fakes.
    case selftest
    /// Latency benchmarks. Side effects go to fakes.
    case bench

    /// True only for ``live``. Features rarely need this: the services already behave correctly.
    public var touchesRealSystem: Bool { self == .live }
}
