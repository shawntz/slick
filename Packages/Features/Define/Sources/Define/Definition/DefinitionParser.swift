import Foundation

/// Turns the plain text Dictionary Services returns into a ``Definition``. Pure: no system calls.
///
/// The text has no markup. An English entry looks like this, all on one line:
///
///     lantern lan·tern | ˈlan(t)ərn | noun 1 a lamp with a case that shields the flame. • the
///     glazed room at the top of a lighthouse. 2 a turret on a roof that lets in light. ORIGIN …
///
/// The parser reads the headword, the syllables and the pronunciation before the second bar. It
/// then cuts the body at parts of speech, at sense numbers in order, at bullets and at the
/// dictionary's section labels. Every character of the body lands in some paragraph, so nothing
/// is lost when a cut is missed. Text with none of these marks, such as an entry from a dictionary
/// in another language, is kept whole, line by line.
nonisolated enum DefinitionParser {
    /// The most characters of an entry the parser reads. The longest English entries run to about
    /// 25,000, so a longer text is cut here and ends with an ellipsis.
    static let maximumLength = 100_000

    static func parse(_ raw: String, term: String) -> Definition {
        let lines = normalizedLines(raw)
        let chars = Array(lines.joined(separator: " "))
        let header = Header.find(in: chars, term: term)
        let paragraphs = Body.paragraphs(Array(chars[header.bodyStart...]))
        let isStructured =
            header.pronunciation != nil
            || paragraphs.contains { paragraph in
                if case .text = paragraph { return false }
                return true
            }
        guard isStructured else {
            return Definition(
                term: term, headword: header.headword ?? term, paragraphs: lines.map(DefinitionParagraph.text),
                isStructured: false)
        }
        return Definition(
            term: term, headword: header.headword ?? term, syllables: header.syllables,
            pronunciation: header.pronunciation, paragraphs: paragraphs, isStructured: true)
    }

    // MARK: Cleaning

    /// The text's lines, each on one line with single spaces: control characters become spaces and
    /// direction overrides are dropped, so a line cannot hide or reorder what it shows.
    static func normalizedLines(_ raw: String) -> [String] {
        var lines: [String] = []
        var line = ""
        var pendingSpace = false
        var count = 0
        func endLine() {
            if !line.isEmpty { lines.append(line) }
            line = ""
            pendingSpace = false
        }
        for character in raw {
            count += 1
            if count > maximumLength {
                line += pendingSpace ? " …" : "…"
                break
            }
            if character.isNewline {
                endLine()
                continue
            }
            if character.isWhitespace || character.unicodeScalars.contains(where: isControl) {
                pendingSpace = !line.isEmpty
                continue
            }
            let kept = String(character.unicodeScalars.filter { !isDirectionControl($0) })
            guard !kept.isEmpty else { continue }
            if pendingSpace { line += " " }
            pendingSpace = false
            line += kept
        }
        endLine()
        return lines
    }

    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control
    }

    /// Embedding, override and isolate controls, which change the order text is drawn in.
    static func isDirectionControl(_ scalar: Unicode.Scalar) -> Bool {
        (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
    }

    /// Lowercased with accents removed, for comparing a headword with what was typed.
    static func folded(_ text: some StringProtocol) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    // MARK: Header

    /// The headword, syllables and pronunciation at the start of an entry, and where the body
    /// starts.
    nonisolated struct Header {
        var headword: String?
        var syllables: String?
        var pronunciation: String?
        var bodyStart = 0

        /// How far into the text the first bar may be, and how long a pronunciation may run.
        static let headLimit = 120
        static let pronunciationLimit = 120

        static func find(in chars: [Character], term: String) -> Header {
            if let header = withPronunciation(chars) { return header }
            if let header = startingWithTerm(chars, term: term) { return header }
            return Header()
        }

        /// "head | pronunciation | body", where the head is the headword, then its syllables, then
        /// a homograph number such as the 1 in "bank 1".
        private static func withPronunciation(_ chars: [Character]) -> Header? {
            guard let open = bar(in: chars, from: 1, limit: headLimit) else { return nil }
            let start = open + 3
            guard let close = bar(in: chars, from: start, limit: start + pronunciationLimit, closing: true) else {
                return nil
            }
            let head = String(chars[0..<open])
            let pronunciation = String(chars[start..<close]).trimmingCharacters(in: .whitespaces)
            let tokens = head.split(separator: " ").map(String.init)
            guard !tokens.isEmpty, tokens.count <= 10, !head.contains(":"), !pronunciation.isEmpty,
                !pronunciation.contains(":")
            else { return nil }
            let (headword, syllables) = splitHead(tokens)
            return Header(
                headword: headword, syllables: syllables, pronunciation: pronunciation,
                bodyStart: min(close + 3, chars.count))
        }

        /// An entry with no pronunciation that starts with the term itself.
        private static func startingWithTerm(_ chars: [Character], term: String) -> Header? {
            let length = term.count
            guard length > 0, chars.count >= length, chars.count == length || chars[length] == " ",
                folded(String(chars[0..<length])) == folded(term)
            else { return nil }
            var header = Header(headword: String(chars[0..<length]), bodyStart: min(length + 1, chars.count))
            var rest = Array(chars[header.bodyStart...]).split(separator: " ", maxSplits: 2).map { String($0) }
            if let first = rest.first, first.contains("·"),
                folded(first.replacingOccurrences(of: "·", with: "")) == folded(term)
            {
                header.syllables = first
                header.bodyStart = min(header.bodyStart + first.count + 1, chars.count)
                rest.removeFirst()
            }
            if let first = rest.first, isHomographNumber(first), rest.count > 1 {
                header.bodyStart = min(header.bodyStart + first.count + 1, chars.count)
            }
            return header
        }

        /// The index of the space before " | ", searching `from` up to `limit`. A closing bar may
        /// also end the text.
        private static func bar(in chars: [Character], from: Int, limit: Int, closing: Bool = false) -> Int? {
            var index = from
            while index + 1 < chars.count, index < limit {
                if chars[index] == " ", chars[index + 1] == "|" {
                    if index + 2 == chars.count, closing { return index }
                    if index + 2 < chars.count, chars[index + 2] == " " { return index }
                }
                index += 1
            }
            return nil
        }

        /// The headword and its syllables from the head's words. "lantern lan·tern" gives
        /// "lantern" and "lan·tern". A trailing homograph number is dropped.
        static func splitHead(_ tokens: [String]) -> (headword: String, syllables: String?) {
            var words = tokens
            if words.count > 1, let last = words.last, isHomographNumber(last) { words.removeLast() }
            for split in 1..<max(words.count, 1) {
                let left = words[..<split].joined(separator: " ")
                let right = words[split...].joined(separator: " ")
                if right.contains("·"), folded(right.replacingOccurrences(of: "·", with: "")) == folded(left) {
                    return (left, right)
                }
            }
            if let dotted = words.firstIndex(where: { $0.contains("·") }), dotted > 0 {
                return (words[..<dotted].joined(separator: " "), words[dotted...].joined(separator: " "))
            }
            let joined = words.joined(separator: " ")
            if joined.contains("·") { return (joined.replacingOccurrences(of: "·", with: ""), joined) }
            return (joined, nil)
        }

        static func isHomographNumber(_ token: String) -> Bool {
            token.count == 1 && token.first.map { ("1"..."9").contains($0) } == true
        }
    }

    // MARK: Body

    nonisolated enum Body {
        /// Labels the dictionary writes in capitals before a section, longest first.
        static let sectionLabels: [[String]] = [
            ["PHRASAL", "VERBS"], ["PHRASES"], ["DERIVATIVES"], ["ORIGIN"], ["USAGE"],
        ]

        /// Parts of speech that may start a group of senses, longest first.
        static let partsOfSpeech: [[String]] = [
            ["plural", "noun"], ["proper", "noun"], ["auxiliary", "verb"], ["modal", "verb"], ["combining", "form"],
            ["cardinal", "number"], ["ordinal", "number"], ["noun"], ["verb"], ["adjective"], ["adverb"],
            ["pronoun"], ["preposition"], ["conjunction"], ["exclamation"], ["interjection"], ["determiner"],
            ["predeterminer"], ["abbreviation"], ["prefix"], ["suffix"], ["contraction"], ["symbol"],
            ["article"], ["number"],
        ]

        /// The most characters a part of speech's grammar note may have before its first sense.
        /// Anything longer is a sense of its own.
        static let noteLimit = 200

        /// The highest sense number the parser follows.
        static let maximumSense = 99

        nonisolated private struct Token {
            let start: Int
            let end: Int
            let text: String
        }

        nonisolated private enum Open {
            case text
            case partOfSpeech(String)
            case sense(Int)
            case subsense
            case section(String)
        }

        static func paragraphs(_ body: [Character]) -> [DefinitionParagraph] {
            let tokens = tokenize(body)
            var paragraphs: [DefinitionParagraph] = []
            var open = Open.text
            var openStart = 0
            var expected = 1
            var inSection = false

            func text(upTo boundary: Int) -> String {
                guard openStart < boundary else { return "" }
                return String(body[openStart..<boundary]).trimmingCharacters(in: .whitespaces)
            }

            func close(at boundary: Int, beforeFirstSense: Bool = false) {
                let text = text(upTo: boundary)
                switch open {
                case .text:
                    if !text.isEmpty { paragraphs.append(.text(text)) }
                case .partOfSpeech(let word):
                    if beforeFirstSense, text.count <= noteLimit {
                        paragraphs.append(.partOfSpeech(word, note: text.isEmpty ? nil : text))
                    } else {
                        paragraphs.append(.partOfSpeech(word, note: nil))
                        if !text.isEmpty { paragraphs.append(.text(text)) }
                    }
                case .sense(let number):
                    if !text.isEmpty { paragraphs.append(.sense(number, text)) }
                case .subsense:
                    if !text.isEmpty { paragraphs.append(.subsense(text)) }
                case .section(let label):
                    if !text.isEmpty { paragraphs.append(.section(label, text)) }
                }
            }

            var index = 0
            while index < tokens.count {
                let token = tokens[index]
                if let label = match(sectionLabels, in: tokens, at: index), index + label.count < tokens.count {
                    close(at: token.start)
                    open = .section(titleCase(label))
                    openStart = tokens[index + label.count].start
                    inSection = true
                    index += label.count
                    continue
                }
                if token.text == "•", index + 1 < tokens.count {
                    close(at: token.start)
                    open = .subsense
                    openStart = tokens[index + 1].start
                    index += 1
                    continue
                }
                if inSection {
                    index += 1
                    continue
                }
                if let words = match(partsOfSpeech, in: tokens, at: index), index + words.count < tokens.count,
                    startsSenses(tokens[index + words.count].text),
                    isAtStart(paragraphs: paragraphs, open: open, before: body[0..<token.start])
                        || (index > 0 && endsSentence(tokens[index - 1].text))
                {
                    close(at: token.start)
                    open = .partOfSpeech(words.joined(separator: " "))
                    openStart = tokens[index + words.count].start
                    expected = 1
                    index += words.count
                    continue
                }
                if expected <= maximumSense, token.text == String(expected), index + 1 < tokens.count,
                    index == 0 || !tokens[index - 1].text.allSatisfy(\.isNumber)
                {
                    close(at: token.start, beforeFirstSense: expected == 1)
                    open = .sense(expected)
                    openStart = tokens[index + 1].start
                    expected += 1
                    index += 1
                    continue
                }
                index += 1
            }
            close(at: body.count)
            return paragraphs
        }

        /// The runs of characters between spaces, with their places in `body`.
        private static func tokenize(_ body: [Character]) -> [Token] {
            var tokens: [Token] = []
            var start: Int?
            for (index, character) in body.enumerated() {
                if character == " " {
                    if let begin = start {
                        tokens.append(Token(start: begin, end: index, text: String(body[begin..<index])))
                    }
                    start = nil
                } else if start == nil {
                    start = index
                }
            }
            if let begin = start {
                tokens.append(Token(start: begin, end: body.count, text: String(body[begin..<body.count])))
            }
            return tokens
        }

        /// The first entry of `candidates` whose words match the tokens at `index` exactly.
        private static func match(_ candidates: [[String]], in tokens: [Token], at index: Int) -> [String]? {
            candidates.first { words in
                index + words.count <= tokens.count
                    && words.indices.allSatisfy { tokens[index + $0].text == words[$0] }
            }
        }

        /// True when the word after a part of speech can begin its senses: a lowercase word, a
        /// bracket, a parenthesis or the first sense number.
        private static func startsSenses(_ next: String) -> Bool {
            guard let first = next.first else { return false }
            return next == "1" || first == "[" || first == "(" || first.isLowercase
        }

        /// True when nothing but variant notes in parentheses, such as "(also naïve)", comes
        /// before this point of the body.
        private static func isAtStart(
            paragraphs: [DefinitionParagraph], open: Open, before prefix: ArraySlice<Character>
        ) -> Bool {
            guard paragraphs.isEmpty, case .text = open else { return false }
            var depth = 0
            for character in prefix {
                switch character {
                case "(": depth += 1
                case ")":
                    depth -= 1
                    if depth < 0 { return false }
                case " ": continue
                default: if depth == 0 { return false }
                }
            }
            return depth == 0
        }

        /// True when a token ends a sentence, allowing closing quotes after the stop.
        private static func endsSentence(_ token: String) -> Bool {
            let trimmed = token.reversed().drop { "’”\"'".contains($0) }
            guard let last = trimmed.first else { return false }
            return ".!?".contains(last)
        }

        /// "PHRASAL VERBS" becomes "Phrasal Verbs".
        private static func titleCase(_ words: [String]) -> String {
            words.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
        }
    }
}
