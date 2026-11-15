import CoreFoundation
import Foundation

/// A JSON value read without trusting its shape, for argument declarations and list output.
///
/// Types stay apart: `true` never reads as a number, and `1` never reads as a boolean.
/// ``decode(_:maximumDepth:)`` refuses deep nesting before parsing, so hostile output cannot
/// exhaust the stack of the thread that parses it.
nonisolated enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Why some bytes are not a JSON value this feature reads.
    nonisolated enum Failure: Error, Hashable, Sendable {
        case empty
        case tooDeep
        case invalid
    }

    /// Parses bytes, refusing empty input and nesting deeper than `maximumDepth`.
    static func decode(_ data: Data, maximumDepth: Int) throws(Failure) -> JSONValue {
        guard data.contains(where: { !Self.isWhitespace($0) }) else { throw .empty }
        guard Self.depth(of: data, limit: maximumDepth) <= maximumDepth else { throw .tooDeep }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw .invalid
        }
        return JSONValue(object)
    }

    /// Converts what `JSONSerialization` returns. Booleans arrive as `NSNumber` too, so their
    /// Core Foundation type tells them from numbers.
    private init(_ object: Any) {
        switch object {
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init))
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues(JSONValue.init))
        default:
            self = .null
        }
    }

    /// The deepest nesting of arrays and objects, counting brackets outside strings. Stops counting
    /// past `limit`.
    static func depth(of data: Data, limit: Int) -> Int {
        var depth = 0
        var deepest = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                deepest = max(deepest, depth)
                if deepest > limit { return deepest }
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                depth -= 1
            default:
                break
            }
        }
        return deepest
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
            || byte == UInt8(ascii: "\t")
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// A string, or a number or boolean written as text, for environment variables.
    var scalarText: String? {
        switch self {
        case .string(let value): value
        case .bool(let value): value ? "true" : "false"
        case .number(let value): value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
        case .null, .array, .object: nil
        }
    }
}
