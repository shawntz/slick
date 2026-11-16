import Foundation
import LocalAuthentication
import Security
import Synchronization

/// The real Keychain, through the `SecItem` calls. Never called in tests: on macOS the file-based
/// keychain can show a password prompt.
///
/// Items are generic passwords keyed by service and account. The backend prefers the data
/// protection keychain, which never shows a prompt for these items, and passes an authentication
/// context that forbids any authentication UI. The data protection keychain needs the app to be
/// signed with a keychain access group. Without one the first call fails with
/// `errSecMissingEntitlement`, and from then on the backend uses the file-based login keychain.
/// There, an item's access list trusts the app's designated requirement, so a build signed with the
/// same identity reads its items silently, while an ad hoc build is a new identity after every
/// rebuild and macOS asks the user before it reads an older item.
nonisolated public final class SecItemKeychain: KeychainBackend {
    private let usesDataProtection: Mutex<Bool>

    /// - Parameter preferDataProtectionKeychain: Start with the data protection keychain. Pass
    ///   false for a build that is known to lack a keychain access group.
    public init(preferDataProtectionKeychain: Bool = true) {
        usesDataProtection = Mutex(preferDataProtectionKeychain)
    }

    /// True while calls go to the data protection keychain.
    public var isUsingDataProtectionKeychain: Bool {
        usesDataProtection.withLock { $0 }
    }

    public func read(service: String, account: String) throws -> Data? {
        try withKeychain { dataProtection in
            var query = Self.itemQuery(service: service, account: account, dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data else { throw KeychainError.unexpectedResult }
                return data
            case errSecItemNotFound:
                return nil
            default:
                throw KeychainError.status(status)
            }
        }
    }

    public func write(_ data: Data, service: String, account: String) throws {
        try withKeychain { dataProtection in
            let query = Self.itemQuery(service: service, account: account, dataProtection: dataProtection)
            let update = [kSecValueData as String: data] as CFDictionary
            let updated = SecItemUpdate(query as CFDictionary, update)
            if updated == errSecSuccess { return }
            guard updated == errSecItemNotFound else { throw KeychainError.status(updated) }

            let item = Self.newItem(query: query, data: data, account: account, dataProtection: dataProtection)
            let added = SecItemAdd(item as CFDictionary, nil)
            if added == errSecDuplicateItem {
                // Another writer added the item between the two calls.
                let retried = SecItemUpdate(query as CFDictionary, update)
                guard retried == errSecSuccess else { throw KeychainError.status(retried) }
                return
            }
            guard added == errSecSuccess else { throw KeychainError.status(added) }
        }
    }

    public func delete(service: String, account: String) throws {
        try withKeychain { dataProtection in
            let query = Self.itemQuery(service: service, account: account, dataProtection: dataProtection)
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
        }
    }

    /// Runs `body` against the data protection keychain, or against the file-based keychain once
    /// the app turned out to lack the entitlement.
    private func withKeychain<T>(_ body: (_ dataProtection: Bool) throws -> T) throws -> T {
        let dataProtection = usesDataProtection.withLock { $0 }
        do {
            return try body(dataProtection)
        } catch KeychainError.status(errSecMissingEntitlement) where dataProtection {
            usesDataProtection.withLock { $0 = false }
            return try body(false)
        }
    }

    /// The query that names one item. Pure, so a test can check it without the Keychain.
    static func itemQuery(service: String, account: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        return query
    }

    /// The attributes of a new item: the query plus its data, a label people recognise in Keychain
    /// Access, and in the data protection keychain an accessibility class that lets background
    /// work read it once the Mac was unlocked after a restart. Items never sync to iCloud.
    static func newItem(query: [String: Any], data: Data, account: String, dataProtection: Bool) -> [String: Any] {
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = account
        item[kSecAttrSynchronizable as String] = false
        if dataProtection {
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        return item
    }
}

/// Why a Keychain call failed.
nonisolated public enum KeychainError: Error, Hashable, Sendable, LocalizedError {
    /// The Keychain returned this status.
    case status(OSStatus)
    /// The stored secret is not UTF-8 text.
    case notText
    /// The Keychain returned something other than the item's data.
    case unexpectedResult

    /// A title, as a failure toast shows it.
    public var errorDescription: String? {
        switch self {
        case .status(let status): "Keychain Error \(status)"
        case .notText: "Stored Secret Is Not Text"
        case .unexpectedResult: "Unexpected Keychain Result"
        }
    }

    /// What happened, as a sentence under the title.
    public var failureReason: String? {
        switch self {
        case .status(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "The Keychain gave no reason"
            return message.hasSuffix(".") ? message : message + "."
        case .notText:
            return "The Keychain holds something other than text for this item."
        case .unexpectedResult:
            return "The Keychain returned something other than the item's data."
        }
    }
}
