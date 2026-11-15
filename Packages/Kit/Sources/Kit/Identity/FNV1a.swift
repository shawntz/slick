/// The 64-bit FNV-1a hash that turns an ``ItemID`` into the engine's key.
///
/// It is fixed by contract with the Rust core: offset basis 0xcbf29ce484222325, prime
/// 0x100000001b3, one round per byte (xor, then multiply with wrap-around). Never change it: every
/// learned weight on disk is keyed by its output.
public enum FNV1a {
    /// The 64-bit FNV offset basis.
    public static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325

    /// The 64-bit FNV prime.
    public static let prime: UInt64 = 0x100_0000_01b3

    /// Hashes the UTF-8 bytes of a string.
    public static func hash64(_ string: String) -> UInt64 {
        var string = string
        return string.withUTF8 { hash64(bytes: $0) }
    }

    /// Hashes a sequence of bytes.
    public static func hash64(bytes: some Sequence<UInt8>) -> UInt64 {
        var hash = offsetBasis
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }
}
