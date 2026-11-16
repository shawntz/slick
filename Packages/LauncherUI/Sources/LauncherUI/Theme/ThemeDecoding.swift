// Theme files outlive the code that wrote them. A part of the theme that gains a field reads its
// file by hand, in its own file where the synthesized coding keys are in scope: old keys are
// required as before, and new keys fall back to a default, often another value of the same file.
// Encoding stays synthesized, so `Theme.standard` still encodes every key.

extension KeyedDecodingContainer {
    /// The value for `key`. A missing key throws, as synthesized decoding does.
    nonisolated func value<T: Decodable>(_ key: Key) throws -> T {
        try decode(T.self, forKey: key)
    }

    /// The value for `key`, or `fallback` when the file was written before the key existed. A key
    /// that is present with a wrong value still throws.
    nonisolated func value<T: Decodable>(_ key: Key, or fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback()
    }
}
