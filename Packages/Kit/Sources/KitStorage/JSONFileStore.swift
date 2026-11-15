import Foundation

/// One Codable value in a JSON file, written atomically: the new file is written beside the old one
/// and renamed over it, so a crash leaves either the old file or the new one, never half of each.
///
/// For small collections a person may read or edit, such as snippets and quicklinks. The file is
/// pretty-printed with sorted keys and ISO 8601 dates with milliseconds, so a date read back equals
/// the date saved to the millisecond; dates without fractional seconds read as well. The store is an
/// actor, so reads and writes of one file never interleave; keep your working copy in memory and
/// save after each change.
///
/// `Value` and its Codable conformance must not be tied to the main actor. In a feature package,
/// declare stored types `nonisolated struct`.
public actor JSONFileStore<Value: Codable & Sendable> {
    /// The file.
    public nonisolated let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The stored value, or nil when the file does not exist. Throws when the file cannot be read or
    /// decoded.
    public func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = (try? Date(text, strategy: Self.fractionalDates)) ?? (try? Date(text, strategy: .iso8601)) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an ISO 8601 date: \(text)")
        }
        return try decoder.decode(Value.self, from: data)
    }

    /// The stored value, or `defaultValue` when the file does not exist.
    public func load(default defaultValue: Value) throws -> Value {
        try load() ?? defaultValue
    }

    /// Writes the value, creating the folder if needed.
    public func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Self.fractionalDates))
        }
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Loads, changes and saves in one step, and returns the saved value.
    @discardableResult
    public func update(default defaultValue: Value, _ change: @Sendable (inout Value) throws -> Void) throws -> Value {
        var value = try load(default: defaultValue)
        try change(&value)
        try save(value)
        return value
    }

    private static var fractionalDates: Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    }

    /// Deletes the file. Does nothing when it does not exist.
    public func delete() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
