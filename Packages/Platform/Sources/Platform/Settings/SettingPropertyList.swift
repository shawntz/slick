import CoreFoundation
import Foundation
import Kit

/// How a ``SettingStorage`` value is written to a property list, such as a `UserDefaults` domain.
///
/// Each case maps to its own property list type, so a value reads back as the case it was written
/// as. `.empty`, a value the user cleared on purpose, is a dictionary with one marker key, because a
/// property list cannot hold nil and no other case uses a dictionary.
nonisolated enum SettingPropertyList {
    /// The marker key of an explicitly empty value.
    static let emptyMarker = "empty"

    /// The property list form of a value.
    static func encode(_ storage: SettingStorage) -> Any {
        switch storage {
        case .bool(let value): value
        case .int(let value): value
        case .double(let value): value
        case .string(let value): value
        case .strings(let value): value
        case .data(let value): value
        case .empty: [emptyMarker: true]
        }
    }

    /// The value a property list object stands for, or nil for a type no setting uses.
    static func decode(_ object: Any) -> SettingStorage? {
        switch object {
        case let number as NSNumber:
            // A Bool arrives as an NSNumber too; CFBoolean tells it apart.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if CFNumberIsFloatType(number) { return .double(number.doubleValue) }
            return .int(number.intValue)
        case let text as String:
            return .string(text)
        case let data as Data:
            return .data(data)
        case let array as [Any]:
            var strings: [String] = []
            strings.reserveCapacity(array.count)
            for element in array {
                guard let text = element as? String else { return nil }
                strings.append(text)
            }
            return .strings(strings)
        case let dictionary as [String: Any]:
            return dictionary[emptyMarker] as? Bool == true ? .empty : nil
        default:
            return nil
        }
    }
}
