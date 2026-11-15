import Foundation

/// A settings value as the settings service stores it. Every ``SettingValue`` maps to one of these,
/// so the live service can keep them in `UserDefaults` without decoding on every read.
public enum SettingStorage: Hashable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case strings([String])
    case data(Data)
    /// Explicitly empty, such as a hotkey the user cleared. Different from never set, which reads as
    /// the key's default.
    case empty
}

/// A type that can be a setting: `Bool`, `Int`, `Double`, `String`, `[String]`, ``KeyCombo``,
/// optionals of these, string enums (declare the conformance; the default does the rest) and
/// Codable types through ``CodableSettingValue``.
public protocol SettingValue: Sendable, Equatable {
    init?(settingStorage: SettingStorage)
    var settingStorage: SettingStorage { get }
}

extension Bool: SettingValue {
    public init?(settingStorage: SettingStorage) {
        guard case .bool(let value) = settingStorage else { return nil }
        self = value
    }

    public var settingStorage: SettingStorage { .bool(self) }
}

extension Int: SettingValue {
    public init?(settingStorage: SettingStorage) {
        guard case .int(let value) = settingStorage else { return nil }
        self = value
    }

    public var settingStorage: SettingStorage { .int(self) }
}

extension Double: SettingValue {
    public init?(settingStorage: SettingStorage) {
        switch settingStorage {
        case .double(let value): self = value
        case .int(let value): self = Double(value)
        default: return nil
        }
    }

    public var settingStorage: SettingStorage { .double(self) }
}

extension String: SettingValue {
    public init?(settingStorage: SettingStorage) {
        guard case .string(let value) = settingStorage else { return nil }
        self = value
    }

    public var settingStorage: SettingStorage { .string(self) }
}

extension Array: SettingValue where Element == String {
    public init?(settingStorage: SettingStorage) {
        guard case .strings(let value) = settingStorage else { return nil }
        self = value
    }

    public var settingStorage: SettingStorage { .strings(self) }
}

extension KeyCombo: SettingValue {
    public init?(settingStorage: SettingStorage) {
        guard case .string(let text) = settingStorage, let combo = KeyCombo(parsing: text) else { return nil }
        self = combo
    }

    public var settingStorage: SettingStorage { .string(description) }
}

extension Optional: SettingValue where Wrapped: SettingValue {
    public init?(settingStorage: SettingStorage) {
        if settingStorage == .empty {
            self = .none
        } else if let value = Wrapped(settingStorage: settingStorage) {
            self = .some(value)
        } else {
            return nil
        }
    }

    public var settingStorage: SettingStorage { self?.settingStorage ?? .empty }
}

extension SettingValue where Self: RawRepresentable, RawValue == String {
    public init?(settingStorage: SettingStorage) {
        guard case .string(let raw) = settingStorage else { return nil }
        self.init(rawValue: raw)
    }

    public var settingStorage: SettingStorage { .string(rawValue) }
}

/// A Codable setting, stored as JSON. Declare the conformance; the default does the rest.
public protocol CodableSettingValue: SettingValue, Codable {}

extension CodableSettingValue {
    public init?(settingStorage: SettingStorage) {
        guard case .data(let data) = settingStorage, let value = try? JSONDecoder().decode(Self.self, from: data) else {
            return nil
        }
        self = value
    }

    public var settingStorage: SettingStorage {
        (try? JSONEncoder().encode(self)).map(SettingStorage.data) ?? .empty
    }
}
