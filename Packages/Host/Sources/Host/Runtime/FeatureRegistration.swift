import Kit

/// How the runtime makes one feature. App lists one per feature, in the order settings shows them.
public struct FeatureRegistration {
    /// The feature's manifest, read before the feature is made.
    public let manifest: FeatureManifest
    let make: @MainActor (FeatureContext) -> any Feature

    /// A feature made with its own ``Feature/init(context:)``.
    public init<F: Feature>(_ type: F.Type) {
        manifest = F.manifest
        make = { F(context: $0) }
    }

    /// A feature made by a closure, for a feature that takes dependencies of its own.
    public init<F: Feature>(_ type: F.Type, make: @escaping @MainActor (FeatureContext) -> F) {
        manifest = F.manifest
        self.make = { make($0) }
    }
}
