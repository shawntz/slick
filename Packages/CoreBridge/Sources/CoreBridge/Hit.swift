import SlickCoreC

/// Which text a hit matched.
public enum MatchField: UInt8, Sendable {
    case title = 0
    case alias = 1
    case keyword = 2
    case userAlias = 3
    /// A learned-band hit that does not match the query's text.
    case none = 255
}

/// Where a hit's rank came from, beyond its text.
public struct HitFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// A user alias matched.
    public static let alias = HitFlags(rawValue: UInt8(SLICK_HIT_ALIAS))
    /// The learned band: the item that holds it in the affinity row for exactly this query.
    public static let learned = HitFlags(rawValue: UInt8(SLICK_HIT_LEARNED))
    /// Query affinity below the band lifted the hit.
    public static let affinity = HitFlags(rawValue: UInt8(SLICK_HIT_AFFINITY))
}

/// One ranked result: a value copy of the C `SlickHit`, so callers never import the C module.
public struct Hit: Hashable, Sendable {
    /// The item.
    public let key: ItemKey
    /// Rank; higher is better.
    public let rank: Int32
    /// Text tier 0 (subsequence) to 6 (exact); 8 learned band, 9 alias prefix, 10 alias exact.
    public let tier: UInt8
    /// Which text matched.
    public let field: MatchField
    /// The item's kind.
    public let kind: ItemKind
    /// Where the rank came from.
    public let flags: HitFlags

    init(_ h: SlickHit) {
        key = ItemKey(rawValue: h.key)
        rank = h.rank
        tier = h.tier
        field = MatchField(rawValue: h.field) ?? .none
        kind = ItemKind(rawValue: h.kind)
        flags = HitFlags(rawValue: h.flags)
    }
}

/// One zero-query suggestion.
public struct Suggestion: Hashable, Sendable {
    /// The item.
    public let key: ItemKey
    /// Model score; higher is better. Comparable only within one list.
    public let score: Float
}

/// A highlight range in UTF-16 code units, ready for `NSRange`.
public struct HighlightRange: Hashable, Sendable {
    /// First UTF-16 unit.
    public let location: Int
    /// Number of UTF-16 units.
    public let length: Int
}
