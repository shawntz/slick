/// The stable identity of anything Slick can show, rank or run.
///
/// An ID is a namespace and a key joined by a colon: `app:com.apple.Safari`, `cmd:clipboard.history`,
/// `file:/tmp/example.txt`. The namespace says who owns the item and the key is unique inside it.
/// The same thing must get the same ID on every launch, because learning, favorites and remembered
/// rows are keyed by it.
///
/// The engine never sees the string. It sees ``engineKey``, the 64-bit FNV-1a hash of the UTF-8
/// bytes of ``rawValue``, computed once when the ID is made. The Rust core implements the same hash,
/// and the vectors in `ItemIDTests` keep the two in step.
public struct ItemID: Hashable, Sendable, CustomStringConvertible {
    /// The full ID, `namespace:key`.
    public let rawValue: String

    /// The 64-bit FNV-1a hash of the UTF-8 bytes of ``rawValue``: the item's key in the engine.
    public let engineKey: UInt64

    /// Makes an ID from a namespace and a key.
    ///
    /// The namespace must pass ``isValidNamespace(_:)``. Namespaces are fixed strings in code, so an
    /// invalid one is a programming error and stops the process. `FeatureHarness` catches it in tests.
    public init(_ namespace: String, _ key: String) {
        precondition(
            Self.isValidNamespace(namespace),
            "invalid ItemID namespace \"\(namespace)\": start with a lowercase letter, then use a-z, 0-9, \".\" or \"-\""
        )
        self.init(validated: namespace + ":" + key)
    }

    /// Parses a full ID such as `app:com.apple.Safari`. Returns nil when there is no colon or the
    /// namespace is invalid.
    public init?(rawValue: String) {
        guard let colon = rawValue.firstIndex(of: ":"), Self.isValidNamespace(rawValue[..<colon]) else {
            return nil
        }
        self.init(validated: rawValue)
    }

    private init(validated rawValue: String) {
        self.rawValue = rawValue
        self.engineKey = FNV1a.hash64(rawValue)
    }

    /// The part before the first colon, for example `file`.
    public var namespace: String {
        guard let colon = rawValue.firstIndex(of: ":") else { return "" }
        return String(rawValue[..<colon])
    }

    /// The part after the first colon, for example `/tmp/example.txt`.
    public var key: String {
        guard let colon = rawValue.firstIndex(of: ":") else { return rawValue }
        return String(rawValue[rawValue.index(after: colon)...])
    }

    public var description: String { rawValue }

    /// True for 1 to 32 characters: a lowercase ASCII letter, then lowercase letters, digits, "." or "-".
    public static func isValidNamespace(_ namespace: some StringProtocol) -> Bool {
        let bytes = namespace.utf8
        guard let first = bytes.first, (1...32).contains(bytes.count),
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(first)
        else { return false }
        return bytes.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-")
        }
    }

    public static func == (lhs: ItemID, rhs: ItemID) -> Bool {
        lhs.engineKey == rhs.engineKey && lhs.rawValue == rhs.rawValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(engineKey)
    }
}

extension ItemID: Codable {
    /// Decodes from the plain string form, `namespace:key`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let id = ItemID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an item ID: \(raw)")
        }
        self = id
    }

    /// Encodes as the plain string form, `namespace:key`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension ItemID {
    /// Namespaces that Root owns. A feature's own sources pick their own namespace, usually the
    /// feature ID, and must not use these, except the one feature ``featureOwners`` names.
    public enum ReservedNamespace {
        /// Commands: `cmd:<feature id>.<command id>`.
        public static let command = "cmd"
        /// Applications: `app:<bundle id>`.
        public static let app = "app"

        /// Every reserved namespace.
        public static let all: Set<String> = [command, app]

        /// The one feature that may use a reserved namespace, by namespace. The Apps feature owns
        /// `app`: Root knows those rows as applications for priors and context, and the feature
        /// lists them. No feature may use `cmd`.
        public static let featureOwners: [String: String] = [app: "apps"]

        /// True when the feature with this ID may use `namespace`.
        public static func allows(_ namespace: String, forFeature featureID: String) -> Bool {
            !all.contains(namespace) || featureOwners[namespace] == featureID
        }
    }

    /// The ID of a feature's command, `cmd:<feature id>.<command id>`.
    public static func command(feature featureID: String, command commandID: String) -> ItemID {
        ItemID(ReservedNamespace.command, featureID + "." + commandID)
    }
}
