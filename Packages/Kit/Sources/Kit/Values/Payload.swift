import Foundation

/// A small piece of data a row carries for its source, such as a database key or the item the row
/// shows.
///
/// A payload made from a value keeps that value in memory. Reading it back with ``decode(_:)`` is a
/// cast, so a list of 50,000 rows can carry its items at no cost, and `actions(for:)` gets the item
/// without a lookup. JSON appears only when root search remembers a row: the value is encoded then,
/// and after a relaunch the source decodes it from that JSON. So the source must be able to derive
/// the row's actions from its ``ItemID`` and payload alone, and a payload should stay under 1 KB.
public struct Payload: Hashable, Sendable {
    private enum Storage: Sendable {
        case string(String)
        case value(any Codable & Hashable & Sendable)
        case json(Data)
    }

    private let storage: Storage

    /// A payload holding one string.
    public init(_ string: String) {
        storage = .string(string)
    }

    /// A payload holding a value. Nothing is encoded until root search remembers the row.
    public init<Value: Codable & Hashable & Sendable>(_ value: Value) {
        storage = .value(value)
    }

    /// The string, when the payload was made from one.
    public var string: String? {
        if case .string(let string) = storage { return string }
        return nil
    }

    /// The value the payload was made with: a cast for a payload made in this run, a JSON decode for
    /// one rebuilt from a snapshot. A string payload decodes as `String`.
    public func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        switch storage {
        case .string(let string):
            if let value = string as? Value { return value }
            throw DecodingError.typeMismatch(
                type, .init(codingPath: [], debugDescription: "payload holds a string, not \(type)"))
        case .value(let value):
            if let value = value as? Value { return value }
            throw DecodingError.typeMismatch(
                type, .init(codingPath: [], debugDescription: "payload holds \(Swift.type(of: value)), not \(type)"))
        case .json(let data):
            return try JSONDecoder().decode(type, from: data)
        }
    }

    /// The JSON form of a value payload. Sorted keys keep it stable, so equal values compare equal
    /// whether or not they came from a snapshot.
    private var json: Data? {
        switch storage {
        case .string: nil
        case .json(let data): data
        case .value(let value): try? Self.encoder.encode(value)
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func == (lhs: Payload, rhs: Payload) -> Bool {
        switch (lhs.storage, rhs.storage) {
        case (.string(let left), .string(let right)): left == right
        case (.value(let left), .value(let right)): AnyHashable(left) == AnyHashable(right)
        case (.json(let left), .json(let right)): left == right
        case (.string, _), (_, .string): false
        default: lhs.json == rhs.json
        }
    }

    /// Hashes only the kind of payload: a value and its snapshot must hash alike, and hashing JSON
    /// for every row would cost more than the collisions do. A row's ID separates rows anyway.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(string == nil)
    }
}

extension Payload: Codable {
    private enum CodingKeys: String, CodingKey {
        case string, json
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let string = try container.decodeIfPresent(String.self, forKey: .string) {
            storage = .string(string)
        } else {
            let json = try container.decode(String.self, forKey: .json)
            storage = .json(Data(json.utf8))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch storage {
        case .string(let string):
            try container.encode(string, forKey: .string)
        case .value(let value):
            try container.encode(String(decoding: try Self.encoder.encode(value), as: UTF8.self), forKey: .json)
        case .json(let data):
            try container.encode(String(decoding: data, as: UTF8.self), forKey: .json)
        }
    }
}
