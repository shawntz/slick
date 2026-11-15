import Foundation
import Kit
import Synchronization

/// Where ``PlatformSettings`` keeps values. The service reads everything once when it starts and
/// answers every later read from memory, so a backend is only asked to load and to write.
nonisolated public protocol SettingsBackend: Sendable {
    /// Every stored value by full name. Called once, when the service is made.
    func loadAll() -> [String: SettingStorage]

    /// Stores a value, or removes it when nil. Called off the main thread, in the order of the
    /// writes.
    func write(_ storage: SettingStorage?, for name: String)
}

/// Settings in a `UserDefaults` domain.
///
/// The app passes nil for its own domain. Tests and other environments pass a throwaway suite name
/// and call ``removeDomain()`` when they finish.
nonisolated public final class UserDefaultsSettingsBackend: SettingsBackend {
    /// `UserDefaults` is thread safe but not marked `Sendable`.
    nonisolated(unsafe) private let defaults: UserDefaults
    /// The persistent domain the values live in.
    public let domainName: String

    /// - Parameter suiteName: The domain to use. Nil uses the app's standard domain, which is named
    ///   after its bundle identifier.
    public init(suiteName: String?) {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            defaults = suite
            domainName = suiteName
        } else {
            defaults = .standard
            domainName = Bundle.main.bundleIdentifier ?? Brand.bundleID
        }
    }

    public func loadAll() -> [String: SettingStorage] {
        let stored = defaults.persistentDomain(forName: domainName) ?? [:]
        var values: [String: SettingStorage] = [:]
        values.reserveCapacity(stored.count)
        for (name, object) in stored {
            if let storage = SettingPropertyList.decode(object) { values[name] = storage }
        }
        return values
    }

    public func write(_ storage: SettingStorage?, for name: String) {
        if let storage {
            defaults.set(SettingPropertyList.encode(storage), forKey: name)
        } else {
            defaults.removeObject(forKey: name)
        }
    }

    /// Deletes the whole domain. For throwaway suites only.
    public func removeDomain() {
        defaults.removePersistentDomain(forName: domainName)
    }
}

/// Settings that live only in memory, for run environments that must not write to disk.
nonisolated public final class MemorySettingsBackend: SettingsBackend {
    private let values: Mutex<[String: SettingStorage]>

    public init(_ values: [String: SettingStorage] = [:]) {
        self.values = Mutex(values)
    }

    /// What the backend holds now, by full name.
    public var stored: [String: SettingStorage] {
        values.withLock { $0 }
    }

    public func loadAll() -> [String: SettingStorage] {
        values.withLock { $0 }
    }

    public func write(_ storage: SettingStorage?, for name: String) {
        values.withLock { $0[name] = storage }
    }
}
