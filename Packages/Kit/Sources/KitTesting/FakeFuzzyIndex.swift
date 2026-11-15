import Foundation
import Kit
import Synchronization

/// Builds ``SimpleFuzzyIndex`` indexes and counts them, so a test can check that a host-filtered
/// list was indexed once and not per keystroke.
public final class FakeFuzzyIndexService: FuzzyIndexService {
    private let built = Mutex<[Int]>([])

    public init() {}

    /// The entry count of every index built, in order.
    public var builtIndexSizes: [Int] { built.withLock { $0 } }

    public func makeIndex(_ entries: [FuzzyEntry]) async -> any FuzzyIndex {
        built.withLock { $0.append(entries.count) }
        return SimpleFuzzyIndex(entries)
    }
}

/// A small, predictable stand-in for the engine's matcher. It folds case and diacritics, finds the
/// strongest tier among the title and keywords (a keyword match counts one tier weaker), and orders
/// by tier, then shorter title, then index, as the ranking contract asks. It has no typo tier and
/// highlights only prefix and substring matches.
public struct SimpleFuzzyIndex: FuzzyIndex {
    private struct Entry {
        let title: String
        let titleWords: [String]
        let titleLength: Int
        let keywords: [(text: String, words: [String])]
    }

    private let entries: [Entry]

    public init(_ entries: [FuzzyEntry]) {
        self.entries = entries.map { entry in
            let title = Self.fold(entry.title)
            return Entry(
                title: title, titleWords: Self.words(title), titleLength: entry.title.utf16.count,
                keywords: entry.keywords.map { keyword in
                    let folded = Self.fold(keyword)
                    return (folded, Self.words(folded))
                })
        }
    }

    public var count: Int { entries.count }

    public func search(_ query: String, limit: Int) -> [FuzzyMatch] {
        let folded = Self.fold(query).trimmingCharacters(in: .whitespaces)
        guard !folded.isEmpty, limit > 0 else { return [] }
        let tokens = Self.words(folded)
        var matches: [FuzzyMatch] = []
        for (index, entry) in entries.enumerated() {
            let titleTier = Self.tier(folded, tokens: tokens, text: entry.title, words: entry.titleWords)
            let keywordTier = entry.keywords.compactMap {
                Self.tier(folded, tokens: tokens, text: $0.text, words: $0.words)
            }
            .min().map(Self.weaker)
            guard let tier = [titleTier, keywordTier].compactMap({ $0 }).min() else { continue }
            let highlights: [Range<Int>]
            if titleTier == tier, let range = entry.title.range(of: folded), tier <= .substring {
                let start = entry.title.utf16.distance(from: entry.title.startIndex, to: range.lowerBound)
                highlights = [start..<(start + folded.utf16.count)]
            } else {
                highlights = []
            }
            let score = (MatchTier.allCases.count - tier.rawValue) * 1_000_000 - min(entry.titleLength, 999_999)
            matches.append(FuzzyMatch(index: index, tier: tier, score: score, highlights: highlights))
        }
        matches.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return Array(matches.prefix(limit))
    }

    private static func tier(_ query: String, tokens: [String], text: String, words: [String]) -> MatchTier? {
        if text == query { return .exact }
        if text.hasPrefix(query) || coversLeadingWords(tokens, words) { return .prefix }
        let initials = String(words.compactMap(\.first))
        if tokens.count == 1, initials.hasPrefix(query) { return .wordPrefix }
        if !tokens.isEmpty, tokens.allSatisfy({ token in words.contains { $0.hasPrefix(token) } }) { return .unordered }
        if text.contains(query) { return .substring }
        if isSubsequence(query.filter { !$0.isWhitespace }, of: text) { return .subsequence }
        return nil
    }

    /// The tier a keyword match counts as: one weaker than the same match on the title. The fake has
    /// no typo tier, so a keyword substring counts as a subsequence.
    private static func weaker(_ tier: MatchTier) -> MatchTier {
        switch tier {
        case .substring, .typo, .subsequence: .subsequence
        default: MatchTier(rawValue: tier.rawValue + 1) ?? .subsequence
        }
    }

    /// True when each query token starts the matching word, in order, from the first word.
    private static func coversLeadingWords(_ tokens: [String], _ words: [String]) -> Bool {
        guard tokens.count > 1, tokens.count <= words.count else { return false }
        return zip(tokens, words).allSatisfy { $1.hasPrefix($0) }
    }

    private static func isSubsequence(_ query: String, of text: String) -> Bool {
        var remaining = query[...]
        for character in text where remaining.first == character {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func words(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
