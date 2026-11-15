/// The engine's identity for an item: the 64-bit FNV-1a hash of its id string, such as
/// `app:com.apple.Safari` or `cmd:clipboard.history`. Swift computes it; Rust never sees the string.
public struct ItemKey: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// The key of the item id `id`: FNV-1a over its UTF-8 bytes (offset basis 0xcbf29ce484222325,
    /// prime 0x100000001b3). Allocates nothing.
    public init(id: String) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        rawValue = hash
    }

    public var description: String { "ItemKey(\(rawValue))" }
}
