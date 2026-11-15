import Foundation

/// A prefix index over every name, name word, keyword and keyword word in the catalog, for the
/// colon search in root, which has 100 µs per keystroke on the main thread.
///
/// Terms are folded (lowercase, no diacritics), split into words on anything but letters and digits,
/// and kept as bytes in one sorted table, so a query costs one binary search and a scan over the
/// terms that start with it. Built once, off the main thread, when the feature activates.
nonisolated struct ColonIndex: Sendable {
    /// How a query matched an entry, strongest first. The tiers follow root search's contract: a
    /// weaker tier never outranks a stronger one. Inside a tier the score decides, then a match on
    /// the name beats a keyword, then the shorter name wins, as the matcher orders the grid.
    enum Tier: UInt8, Comparable {
        /// The query is the whole name.
        case exact
        /// The name starts with the query, or a keyword is the query.
        case prefix
        /// Every word of the query starts a word of the name.
        case nameWords
        /// Every word of the query starts a word of the name or a keyword.
        case keywords

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private enum Kind: UInt8 {
        case name, nameWord, keyword, keywordWord
    }

    /// Reusable buffers for ``search(_:limit:includeSymbols:frecency:scratch:)``, so a keystroke
    /// allocates nothing after the first.
    struct Scratch {
        fileprivate var stamps: [UInt32]
        /// Per entry, its best tier times two, plus one when that match came from a keyword only.
        fileprivate var tiers: [UInt8]
        fileprivate var generation: UInt32 = 0
        fileprivate var candidates: [Int32] = []
        fileprivate var tokens: [[UInt8]] = []

        init(count: Int) {
            stamps = [UInt32](repeating: 0, count: count)
            tiers = [UInt8](repeating: 0, count: count)
            candidates.reserveCapacity(512)
        }
    }

    /// One match.
    struct Match: Hashable {
        let position: Int
        let tier: Tier
    }

    private let bytes: [UInt8]
    private let starts: [Int32]
    private let lengths: [UInt16]
    private let owners: [Int32]
    private let kinds: [Kind]
    /// Each entry's word terms, as indexes into the term table: its name words first, then its
    /// keyword words. Entry `n` owns `wordTerms[wordStarts[n]..<wordStarts[n + 1]]`, of which the
    /// first `nameWordCounts[n]` are name words.
    private let wordStarts: [Int32]
    private let wordTerms: [Int32]
    private let nameWordCounts: [UInt8]
    private let isEmoji: [Bool]
    /// Each entry's score without usage. See ``EmojiRanking``.
    private let scores: [Double]
    /// Each entry's name length in characters, for the last tie-break.
    private let nameLengths: [UInt16]

    /// The number of entries.
    let count: Int

    init(catalog: EmojiCatalog) {
        struct Term {
            var text: [UInt8]
            var owner: Int32
            var kind: Kind
        }
        let entries = catalog.entries
        var terms: [Term] = []
        terms.reserveCapacity(entries.count * 12)
        for (position, entry) in entries.enumerated() {
            let owner = Int32(position)
            let nameWords = Self.words(entry.name)
            terms.append(Term(text: Self.join(nameWords), owner: owner, kind: .name))
            var seen = Set<[UInt8]>()
            for word in nameWords where seen.insert(word).inserted {
                terms.append(Term(text: word, owner: owner, kind: .nameWord))
            }
            for keyword in entry.keywords {
                let keywordWords = Self.words(keyword)
                guard !keywordWords.isEmpty else { continue }
                terms.append(Term(text: Self.join(keywordWords), owner: owner, kind: .keyword))
                for word in keywordWords where seen.insert(word).inserted {
                    terms.append(Term(text: word, owner: owner, kind: .keywordWord))
                }
            }
        }
        terms.sort { $0.text.lexicographicallyPrecedes($1.text) }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(terms.reduce(0) { $0 + $1.text.count })
        var starts: [Int32] = []
        var lengths: [UInt16] = []
        var owners: [Int32] = []
        var kinds: [Kind] = []
        var nameWordsByEntry = [[Int32]](repeating: [], count: entries.count)
        var keywordWordsByEntry = [[Int32]](repeating: [], count: entries.count)
        for (index, term) in terms.enumerated() {
            starts.append(Int32(bytes.count))
            lengths.append(UInt16(min(term.text.count, Int(UInt16.max))))
            bytes.append(contentsOf: term.text)
            owners.append(term.owner)
            kinds.append(term.kind)
            switch term.kind {
            case .nameWord: nameWordsByEntry[Int(term.owner)].append(Int32(index))
            case .keywordWord: keywordWordsByEntry[Int(term.owner)].append(Int32(index))
            case .name, .keyword: break
            }
        }
        var wordStarts: [Int32] = [0]
        var wordTerms: [Int32] = []
        var nameWordCounts: [UInt8] = []
        for position in entries.indices {
            wordTerms += nameWordsByEntry[position]
            wordTerms += keywordWordsByEntry[position]
            wordStarts.append(Int32(wordTerms.count))
            nameWordCounts.append(UInt8(min(nameWordsByEntry[position].count, Int(UInt8.max))))
        }
        self.bytes = bytes
        self.starts = starts
        self.lengths = lengths
        self.owners = owners
        self.kinds = kinds
        self.wordStarts = wordStarts
        self.wordTerms = wordTerms
        self.nameWordCounts = nameWordCounts
        isEmoji = entries.map(\.group.isEmoji)
        scores = entries.map(EmojiRanking.staticScore)
        nameLengths = entries.map { UInt16(min($0.name.count, Int(UInt16.max))) }
        count = entries.count
    }

    /// The most words a query may have. No name has more than nine, and each extra word adds a pass
    /// over the candidates.
    static let maximumWords = 10

    /// The best matches for a query, best first: by tier, then by score with usage, then a name match
    /// before a keyword match, then the shorter name, then position.
    /// `query` is the text after the colon. `frecency` maps entry positions to their frecency.
    func search(
        _ query: Substring, limit: Int, includeSymbols: Bool, frecency: [Int: Double], scratch: inout Scratch
    ) -> [Match] {
        Self.words(query, into: &scratch.tokens)
        guard (1...Self.maximumWords).contains(scratch.tokens.count), limit > 0, scratch.stamps.count == count else {
            return []
        }
        scratch.generation &+= 1
        if scratch.generation == 0 {
            for index in scratch.stamps.indices { scratch.stamps[index] = 0 }
            scratch.generation = 1
        }
        scratch.candidates.removeAll(keepingCapacity: true)

        let tokens = scratch.tokens
        if tokens.count == 1 {
            let token = tokens[0]
            forEachTerm(startingWith: token) { term in
                let exact = Int(lengths[term]) == token.count
                switch kinds[term] {
                case .name: note(owners[term], exact ? .exact : .prefix, fromName: true, &scratch)
                case .keyword: note(owners[term], exact ? .prefix : .keywords, fromName: false, &scratch)
                case .nameWord: note(owners[term], .nameWords, fromName: true, &scratch)
                case .keywordWord: note(owners[term], .keywords, fromName: false, &scratch)
                }
            }
        } else {
            let joined = Self.join(tokens)
            forEachTerm(startingWith: joined) { term in
                let exact = Int(lengths[term]) == joined.count
                switch kinds[term] {
                case .name: note(owners[term], exact ? .exact : .prefix, fromName: true, &scratch)
                case .keyword: note(owners[term], exact ? .prefix : .keywords, fromName: false, &scratch)
                case .nameWord, .keywordWord: break
                }
            }
            forEachTerm(startingWith: tokens[0]) { term in
                let owner = owners[term]
                let position = Int(owner)
                if scratch.stamps[position] == scratch.generation,
                    scratch.tiers[position] >> 1 <= Tier.nameWords.rawValue
                {
                    return
                }
                if allTokensStartWords(tokens, of: position, namesOnly: true) {
                    note(owner, .nameWords, fromName: true, &scratch)
                } else if allTokensStartWords(tokens, of: position, namesOnly: false) {
                    note(owner, .keywords, fromName: false, &scratch)
                }
            }
        }
        return best(limit: limit, includeSymbols: includeSymbols, frecency: frecency, scratch: scratch)
    }

    // MARK: Matching

    /// Keeps the entry's best match: the stronger tier, and in one tier a match on the name.
    private func note(_ owner: Int32, _ tier: Tier, fromName: Bool, _ scratch: inout Scratch) {
        let position = Int(owner)
        let rank = tier.rawValue << 1 | (fromName ? 0 : 1)
        if scratch.stamps[position] != scratch.generation {
            scratch.stamps[position] = scratch.generation
            scratch.tiers[position] = rank
            scratch.candidates.append(owner)
        } else if rank < scratch.tiers[position] {
            scratch.tiers[position] = rank
        }
    }

    private func allTokensStartWords(_ tokens: [[UInt8]], of position: Int, namesOnly: Bool) -> Bool {
        let start = Int(wordStarts[position])
        let end = namesOnly ? start + Int(nameWordCounts[position]) : Int(wordStarts[position + 1])
        return tokens.allSatisfy { token in
            (start..<end).contains { termStarts(with: token, Int(wordTerms[$0])) }
        }
    }

    private struct Candidate {
        let match: Match
        let score: Double
        let fromName: Bool
        let nameLength: UInt16
    }

    private func best(limit: Int, includeSymbols: Bool, frecency: [Int: Double], scratch: Scratch) -> [Match] {
        var best: [Candidate] = []
        best.reserveCapacity(limit + 1)
        for owner in scratch.candidates {
            let position = Int(owner)
            let rank = scratch.tiers[position]
            guard includeSymbols || isEmoji[position], let tier = Tier(rawValue: rank >> 1) else { continue }
            let candidate = Candidate(
                match: Match(position: position, tier: tier),
                score: scores[position] + (frecency[position] ?? 0) * EmojiRanking.usageWeight,
                fromName: rank & 1 == 0, nameLength: nameLengths[position])
            let place = best.firstIndex { Self.ranks(candidate, before: $0) } ?? best.count
            guard place < limit else { continue }
            best.insert(candidate, at: place)
            if best.count > limit { best.removeLast() }
        }
        return best.map(\.match)
    }

    private static func ranks(_ lhs: Candidate, before rhs: Candidate) -> Bool {
        if lhs.match.tier != rhs.match.tier { return lhs.match.tier < rhs.match.tier }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.fromName != rhs.fromName { return lhs.fromName }
        if lhs.nameLength != rhs.nameLength { return lhs.nameLength < rhs.nameLength }
        return lhs.match.position < rhs.match.position
    }

    // MARK: The term table

    /// Calls `body` with every term that starts with `prefix`.
    private func forEachTerm(startingWith prefix: [UInt8], _ body: (Int) -> Void) {
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if compare(middle, prefix) < 0 { low = middle + 1 } else { high = middle }
        }
        var term = low
        while term < starts.count, termStarts(with: prefix, term) {
            body(term)
            term += 1
        }
    }

    /// Compares a term with `other`, byte by byte.
    private func compare(_ term: Int, _ other: [UInt8]) -> Int {
        let start = Int(starts[term])
        let length = Int(lengths[term])
        let shared = min(length, other.count)
        for offset in 0..<shared {
            let left = bytes[start + offset]
            let right = other[offset]
            if left != right { return left < right ? -1 : 1 }
        }
        return length == other.count ? 0 : (length < other.count ? -1 : 1)
    }

    private func termStarts(with prefix: [UInt8], _ term: Int) -> Bool {
        let start = Int(starts[term])
        guard Int(lengths[term]) >= prefix.count else { return false }
        for offset in prefix.indices where bytes[start + offset] != prefix[offset] { return false }
        return true
    }

    // MARK: Folding

    /// The folded words of a text: lowercase, without diacritics, split on anything but letters and
    /// digits.
    static func words(_ text: some StringProtocol) -> [[UInt8]] {
        var words: [[UInt8]] = []
        Self.words(text, into: &words)
        return words
    }

    /// The same as ``words(_:)``, into a buffer that keeps its capacity.
    static func words(_ text: some StringProtocol, into words: inout [[UInt8]]) {
        words.removeAll(keepingCapacity: true)
        var current: [UInt8] = []
        func endWord() {
            guard !current.isEmpty else { return }
            words.append(current)
            current.removeAll(keepingCapacity: true)
        }
        if text.utf8.allSatisfy({ $0 < 0x80 }) {
            // The common case, and the one a keystroke takes: no Foundation call, no allocation per
            // character.
            for byte in text.utf8 {
                switch byte {
                case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                    current.append(byte)
                case UInt8(ascii: "A")...UInt8(ascii: "Z"):
                    current.append(byte + 32)
                default:
                    endWord()
                }
            }
        } else {
            let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            for scalar in folded.unicodeScalars {
                if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                    UTF8.encode(scalar) { current.append($0) }
                } else {
                    endWord()
                }
            }
        }
        endWord()
    }

    private static func join(_ words: [[UInt8]]) -> [UInt8] {
        var joined: [UInt8] = []
        for (index, word) in words.enumerated() {
            if index > 0 { joined.append(UInt8(ascii: " ")) }
            joined += word
        }
        return joined
    }
}
