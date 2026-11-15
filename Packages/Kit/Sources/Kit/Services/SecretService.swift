/// Secrets such as API keys and tokens. The live service keeps them in the Keychain, never in
/// settings, so they are not written to disk in plain text. Features use ``FeatureSecrets``, which
/// adds the feature's prefix.
public protocol SecretService: Sendable {
    /// The stored secret, or nil when there is none.
    @concurrent func secret(for name: String) async throws -> String?

    /// Stores a secret. Nil deletes it.
    @concurrent func setSecret(_ value: String?, for name: String) async throws
}

/// A feature's secrets, namespaced under the feature ID as `<feature id>.<name>`. The settings
/// window edits them through ``SettingsItem/secret(_:name:placeholder:info:)``.
public struct FeatureSecrets: Sendable {
    public let featureID: String
    private let service: any SecretService

    public init(featureID: String, service: any SecretService) {
        self.featureID = featureID
        self.service = service
    }

    /// The name under which the service stores a secret.
    public func storageName(for name: String) -> String {
        featureID + "." + name
    }

    /// The secret, or nil when the user has not set it.
    public func value(for name: String) async throws -> String? {
        try await service.secret(for: storageName(for: name))
    }

    /// Stores a secret. Nil deletes it.
    public func set(_ value: String?, for name: String) async throws {
        try await service.setSecret(value, for: storageName(for: name))
    }
}
