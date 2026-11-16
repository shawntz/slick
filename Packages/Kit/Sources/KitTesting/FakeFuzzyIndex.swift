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

/// A small, predictable stand-in for the engine's matcher over a feature's list. It folds case and
/// diacritics and finds the strongest tier among the title and keywords. A keyword equal to the
/// whole query counts as exact, as a title equal to it does; any other keyword match counts one tier
/// weaker than the same match on the title. It orders as the engine does: by tier, then a title
/// match before a keyword match, then shorter title, then index. It has no typo tier.
///
/// A match the title made has ``FuzzyMatch/matchesTitle`` set and carries the title's matched
/// ranges. A match a keyword made carries none, as with the engine. Ranges are UTF-16 offsets in
/// the folded title, which equal the title's own for text without decomposed characters.
public struct SimpleFuzzyIndex: FuzzyIndex {
    private struct Entry {
        let title: Text
        let titleLength: Int
        let keywords: [Text]
    }

    /// Folded text with its words and where each word starts, in UTF-16 offsets.
    private struct Text {
        let folded: String
        let words: [(text: String, start: Int)]

        init(_ text: String) {
            folded = SimpleFuzzyIndex.fold(text)
            words = SimpleFuzzyIndex.words(folded)
        }
    }

    private let entries: [Entry]

    public init(_ entries: [FuzzyEntry]) {
        self.entries = entries.map { entry in
            Entry(
                title: Text(entry.title), titleLength: entry.title.utf16.count, keywords: entry.keywords.map(Text.init))
        }
    }

    public var count: Int { entries.count }

    public func search(_ query: String, limit: Int) -> [FuzzyMatch] {
        let folded = Self.fold(query).trimmingCharacters(in: .whitespaces)
        guard !folded.isEmpty, limit > 0 else { return [] }
        let tokens = Self.words(folded).map(\.text)
        var matches: [FuzzyMatch] = []
        for (index, entry) in entries.enumerated() {
            let title = Self.match(folded, tokens: tokens, in: entry.title)
            let keyword = entry.keywords.compactMap { Self.match(folded, tokens: tokens, in: $0)?.tier }
                .min().map(Self.keywordTier)
            guard let tier = [title?.tier, keyword].compactMap({ $0 }).min() else { continue }
            // At equal tiers the title wins, as the engine's field bonus decides.
            let isTitleMatch = title?.tier == tier
            let highlights = isTitleMatch ? title?.ranges ?? [] : []
            let tierScore = (MatchTier.allCases.count - tier.rawValue) * 2_000_000
            let score = tierScore + (isTitleMatch ? 1_000_000 : 0) - min(entry.titleLength, 999_999)
            matches.append(
                FuzzyMatch(
                    index: index, tier: tier, score: score, highlights: highlights, matchesTitle: isTitleMatch))
        }
        matches.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return Array(matches.prefix(limit))
    }

    /// A tier with the ranges that matched in it.
    private typealias TextMatch = (tier: MatchTier, ranges: [Range<Int>])

    /// The tier a text matches the query at, with the matched ranges of that match.
    private static func match(_ query: String, tokens: [String], in text: Text) -> TextMatch? {
        let length = query.utf16.count
        if text.folded == query { return (.exact, [0..<length]) }
        if text.folded.hasPrefix(query) { return (.prefix, [0..<length]) }
        if tokens.count > 1, tokens.count <= text.words.count,
            zip(tokens, text.words).allSatisfy({ $1.text.hasPrefix($0) })
        {
            return (.prefix, zip(tokens, text.words).map { $1.start..<($1.start + $0.utf16.count) })
        }
        let initials = String(text.words.compactMap(\.text.first))
        if tokens.count == 1, initials.hasPrefix(query) {
            return (.wordPrefix, text.words.prefix(query.count).map { $0.start..<($0.start + 1) })
        }
        if !tokens.isEmpty {
            let starts = tokens.map { token in
                text.words.first { $0.text.hasPrefix(token) }.map { $0.start..<($0.start + token.utf16.count) }
            }
            if starts.allSatisfy({ $0 != nil }) { return (.unordered, merged(starts.compactMap { $0 })) }
        }
        if let range = text.folded.range(of: query) {
            let start = text.folded.utf16.distance(from: text.folded.startIndex, to: range.lowerBound)
            return (.substring, [start..<(start + length)])
        }
        if let positions = subsequence(query.filter { !$0.isWhitespace }, of: text.folded) {
            return (.subsequence, merged(positions.map { $0..<($0 + 1) }))
        }
        return nil
    }

    /// The tier a keyword match counts as: exact when the keyword equals the query, otherwise one
    /// weaker than the same match on the title. The fake has no typo tier, so a keyword substring
    /// counts as a subsequence.
    private static func keywordTier(_ tier: MatchTier) -> MatchTier {
        switch tier {
        case .exact: .exact
        case .substring, .typo, .subsequence: .subsequence
        default: MatchTier(rawValue: tier.rawValue + 1) ?? .subsequence
        }
    }

    /// The UTF-16 offsets of the query's characters found in order in the text, or nil.
    private static func subsequence(_ query: String, of text: String) -> [Int]? {
        guard !query.isEmpty else { return nil }
        var remaining = query[...]
        var positions: [Int] = []
        var offset = 0
        for character in text {
            if remaining.first == character {
                positions.append(offset)
                remaining = remaining.dropFirst()
                if remaining.isEmpty { return positions }
            }
            offset += character.utf16.count
        }
        return nil
    }

    /// Ranges sorted, with touching and overlapping ones joined.
    private static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    fileprivate static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The words of a text: runs of letters and digits, each with its UTF-16 start.
    fileprivate static func words(_ text: String) -> [(text: String, start: Int)] {
        var words: [(text: String, start: Int)] = []
        var current = ""
        var start = 0
        var offset = 0
        for character in text {
            if character.isLetter || character.isNumber {
                if current.isEmpty { start = offset }
                current.append(character)
            } else if !current.isEmpty {
                words.append((current, start))
                current = ""
            }
            offset += character.utf16.count
        }
        if !current.isEmpty { words.append((current, start)) }
        return words
    }
}
