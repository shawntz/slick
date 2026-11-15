/// Builds fuzzy-search indexes over strings with the engine's matcher, the same one root search uses.
///
/// The host uses it to filter lists with ``ListFiltering/host``. A feature with custom filtering can
/// build its own index once and search it per query.
public protocol FuzzyIndexService: Sendable {
    /// Builds an index. The work runs off the main thread, whoever calls it.
    @concurrent func makeIndex(_ entries: [FuzzyEntry]) async -> any FuzzyIndex
}

/// A built index. Searching is synchronous and meant for the main thread: the engine's root query
/// over 10,000 titles takes 61 µs at the median.
public protocol FuzzyIndex: Sendable {
    var count: Int { get }

    /// Entries that match the query, best first, at most `limit`. Ranking follows the engine's text
    /// tiers: a weaker tier never outranks a stronger one; ties go to the shorter title, then to the
    /// lower index.
    func search(_ query: String, limit: Int) -> [FuzzyMatch]
}

/// One searchable entry: a title and extra words.
public struct FuzzyEntry: Hashable, Sendable {
    public var title: String
    public var keywords: [String]

    public init(title: String, keywords: [String] = []) {
        self.title = title
        self.keywords = keywords
    }
}

/// One search hit.
public struct FuzzyMatch: Hashable, Sendable {
    /// The entry's position in the array the index was built from.
    public var index: Int
    public var tier: MatchTier
    /// Higher is better. Only comparable within one search.
    public var score: Int
    /// Matched ranges of the title in UTF-16 offsets, for highlighting.
    public var highlights: [Range<Int>]

    public init(index: Int, tier: MatchTier, score: Int, highlights: [Range<Int>] = []) {
        self.index = index
        self.tier = tier
        self.score = score
        self.highlights = highlights
    }
}

/// How a query matched, strongest first. See "Matching" in docs/ARCHITECTURE.md.
public enum MatchTier: Int, Hashable, Sendable, Comparable, CaseIterable {
    /// The title equals the query.
    case exact
    /// The title starts with the query, or the query covers leading words in order.
    case prefix
    /// Acronyms, camel case, skipped words.
    case wordPrefix
    /// Every query word starts a title word, in any order.
    case unordered
    /// The query appears inside a word.
    case substring
    /// One edit away at a word start. Ranks above a scattered subsequence, so `calender` finds
    /// Calendar.
    case typo
    /// The query's letters appear in order, scattered.
    case subsequence

    /// Stronger tiers compare as smaller: `.exact < .subsequence`.
    public static func < (lhs: MatchTier, rhs: MatchTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
