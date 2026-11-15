/// Names a service only one feature uses, such as the window mover or the calendar store, with the
/// implementation for each kind of run.
///
/// The feature gets its service with ``FeatureContext/service(_:)`` in ``Feature/init(context:)``
/// and keeps it. In the app that is ``live(_:)``; in scenarios, self-tests and benchmarks it is
/// ``isolated(_:)``, which must not touch the real Mac; in tests it is whatever the test passed to
/// `FakeServices.override(_:with:)`. So the feature never branches on the run environment.
///
/// ```swift
/// nonisolated enum WindowServiceKey: FeatureServiceKey {
///     static func live(_ context: FeatureContext) -> any WindowService { AccessibilityWindows() }
///     static func isolated(_ context: FeatureContext) -> any WindowService { SimulatedWindows() }
/// }
/// windows = context.service(WindowServiceKey.self)
/// ```
public protocol FeatureServiceKey {
    associatedtype Value: Sendable

    /// The implementation that works on the real Mac.
    static func live(_ context: FeatureContext) -> Value

    /// An implementation with no side effects outside the run's temporary folder, for scenarios,
    /// self-tests and benchmarks.
    static func isolated(_ context: FeatureContext) -> Value
}

/// Implementations of feature services that replace the usual choice, set by tests.
public struct ServiceOverrides: Sendable {
    private var values: [ObjectIdentifier: any Sendable] = [:]

    public init() {}

    /// The implementation set for a key, if any.
    public subscript<Key: FeatureServiceKey>(key: Key.Type) -> Key.Value? {
        get { values[ObjectIdentifier(key)] as? Key.Value }
        set { values[ObjectIdentifier(key)] = newValue }
    }
}

extension FeatureContext {
    /// The feature's own service for this run: an override, else ``FeatureServiceKey/live(_:)`` in the
    /// app, else ``FeatureServiceKey/isolated(_:)``. Each call makes a new one; keep it.
    public func service<Key: FeatureServiceKey>(_ key: Key.Type) -> Key.Value {
        if let override = overrides[key] { return override }
        return environment.touchesRealSystem ? Key.live(self) : Key.isolated(self)
    }
}
