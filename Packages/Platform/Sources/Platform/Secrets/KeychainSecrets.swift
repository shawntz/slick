import Foundation
import Kit
import Synchronization

/// The few Keychain operations the secret service needs. ``SecItemKeychain`` talks to the real
/// Keychain; ``MemoryKeychain`` keeps items in memory for tests and for run environments other than
/// `live`.
nonisolated public protocol KeychainBackend: Sendable {
    /// The item's data, or nil when there is no such item.
    func read(service: String, account: String) throws -> Data?

    /// Adds the item, or replaces its data when it exists.
    func write(_ data: Data, service: String, account: String) throws

    /// Removes the item. Removing a missing item is not an error.
    func delete(service: String, account: String) throws
}

/// The live secret service: one generic password item per secret, with the secret's full name as
/// the account and ``service`` as the service.
///
/// Every call runs off the main thread, because the Keychain answers over XPC.
nonisolated public final class KeychainSecrets: SecretService {
    /// The Keychain service name the items share.
    public let service: String
    private let backend: any KeychainBackend

    /// - Parameters:
    ///   - service: The Keychain service name. Defaults to ``defaultService``.
    ///   - backend: Where items live. The app passes ``SecItemKeychain``; tests pass
    ///     ``MemoryKeychain``.
    public init(service: String = KeychainSecrets.defaultService, backend: any KeychainBackend) {
        self.service = service
        self.backend = backend
    }

    /// The bundle identifier plus ".secrets".
    public static var defaultService: String { Brand.bundleID + ".secrets" }

    @concurrent public func secret(for name: String) async throws -> String? {
        guard let data = try backend.read(service: service, account: name) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { throw KeychainError.notText }
        return text
    }

    @concurrent public func setSecret(_ value: String?, for name: String) async throws {
        if let value {
            try backend.write(Data(value.utf8), service: service, account: name)
        } else {
            try backend.delete(service: service, account: name)
        }
    }
}

/// Keychain items in memory.
nonisolated public final class MemoryKeychain: KeychainBackend {
    private struct ItemKey: Hashable {
        var service: String
        var account: String
    }

    private let items = Mutex<[ItemKey: Data]>([:])

    public init() {}

    /// How many items are stored.
    public var count: Int {
        items.withLock { $0.count }
    }

    public func read(service: String, account: String) throws -> Data? {
        items.withLock { $0[ItemKey(service: service, account: account)] }
    }

    public func write(_ data: Data, service: String, account: String) throws {
        items.withLock { $0[ItemKey(service: service, account: account)] = data }
    }

    public func delete(service: String, account: String) throws {
        _ = items.withLock { $0.removeValue(forKey: ItemKey(service: service, account: account)) }
    }
}
