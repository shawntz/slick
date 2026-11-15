/// Stores settings by full key name. The live service keeps them in `UserDefaults`. Features use
/// ``FeatureSettings``, which adds the feature's prefix and the types.
public protocol SettingsService: Sendable {
    /// The stored value, or nil when it was never set. Instant providers read settings on every
    /// keystroke, so this must be an in-memory lookup that never waits on a lock held across I/O.
    func storage(for name: String) -> SettingStorage?

    /// Stores a value. Nil removes it, so reads return the default again.
    func set(_ storage: SettingStorage?, for name: String)

    /// The full name of each key among `names` that changes from now on, from any writer: a feature,
    /// the settings window or a reset. A write that leaves the stored value as it was is not a
    /// change. Each call returns its own stream; it ends when the consuming task is cancelled.
    func changes(for names: Set<String>) -> AsyncStream<String>
}

/// A feature's settings, typed and namespaced under the feature ID.
public struct FeatureSettings: Sendable {
    public let featureID: String
    private let service: any SettingsService

    public init(featureID: String, service: any SettingsService) {
        self.featureID = featureID
        self.service = service
    }

    /// The name under which the service stores a key: `<feature id>.<key name>`.
    public func storageName(for keyName: String) -> String {
        featureID + "." + keyName
    }

    /// Reads and writes a setting. Reading is cheap; it returns the default when the stored value is
    /// missing or of another type.
    public subscript<Value>(key: SettingKey<Value>) -> Value {
        get {
            service.storage(for: storageName(for: key.name)).flatMap(Value.init(settingStorage:)) ?? key.defaultValue
        }
        nonmutating set {
            service.set(newValue.settingStorage, for: storageName(for: key.name))
        }
    }

    /// The setting's value as stored, without its type. For hosts and tests.
    public func storage(of key: AnySettingKey) -> SettingStorage {
        service.storage(for: storageName(for: key.name)) ?? key.defaultValue
    }

    /// Forgets the stored value, so reads return the default.
    public func reset<Value>(_ key: SettingKey<Value>) {
        service.set(nil, for: storageName(for: key.name))
    }

    /// The setting's value after every later change. It ends when the consuming task is cancelled.
    /// Values are read when the consumer asks for the next one, with no task in between, so a test's
    /// `settle()` knows when the consumer is done.
    public func changes<Value>(of key: SettingKey<Value>) -> AsyncMapSequence<AsyncStream<String>, Value> {
        let settings = self
        return service.changes(for: [storageName(for: key.name)]).map { _ in settings[key] }
    }

    /// The name of each of these keys that changes from now on, one stream for all of them. For work
    /// that depends on several settings, such as restarting text expansion.
    public func changes(ofAny keys: [AnySettingKey]) -> AsyncMapSequence<AsyncStream<String>, String> {
        let prefix = featureID.count + 1
        return service.changes(for: Set(keys.map { storageName(for: $0.name) })).map { String($0.dropFirst(prefix)) }
    }
}
