import Foundation

/// A root search query that asks for a translation: "translate <text>" or "tr <text>", optionally
/// ending in "to <language>". Pure, and cheap enough for every keystroke: anything that does not
/// start with "t" is turned away on its first byte.
nonisolated enum RootKeyword {
    private static let long = Array("translate ".utf8)
    private static let short = Array("tr ".utf8)
    private static let to = Array(" to ".utf8)
    /// The titles of commands that begin with the long keyword, in lowercase: the feature's own
    /// Translate Selection and the AI feature's Translate with AI. While a query can still grow
    /// into one of them, the user is looking for that command, and a translation row claiming the
    /// top would take its place and its Return.
    private static let commandTitles = [Array("translate selection".utf8), Array("translate with ai".utf8)]

    /// The text after a keyword, or nil. The keyword may be in any case and needs a space and some
    /// text after it. A query on its way to one of ``commandTitles``, such as "translate sel" for
    /// Translate Selection, is not text to translate.
    static func text(in query: String) -> Substring? {
        let bytes = query.utf8
        guard let first = bytes.first, first | 0x20 == UInt8(ascii: "t") else { return nil }
        // Plain checks, so a query that starts with "t" allocates nothing either.
        let index: String.Index
        if let end = end(of: long, in: query) {
            guard !commandTitles.contains(where: { isStart(of: $0, query: query) }) else { return nil }
            index = end
        } else if let end = end(of: short, in: query) {
            index = end
        } else {
            return nil
        }
        let rest = query[index...]
        return rest.utf8.contains(where: { $0 != 0x20 }) ? rest : nil
    }

    /// True when the whole query is the start of a lowercase title, compared without case.
    private static func isStart(of title: [UInt8], query: String) -> Bool {
        let bytes = query.utf8
        var index = bytes.startIndex
        for expected in title {
            guard index != bytes.endIndex else { return true }
            let byte = bytes[index]
            guard expected == 0x20 ? byte == 0x20 : byte | 0x20 == expected else { return false }
            index = bytes.index(after: index)
        }
        return index == bytes.endIndex
    }

    /// The text and the language, when the text ends in "to" and a name the catalog knows. The
    /// name is looked up only when it is short, so a long text costs one scan for " to ".
    static func request(_ text: Substring, catalog: LanguageCatalog) -> RootRequest {
        if let split = lastTo(in: text) {
            let name = text[split.upperBound...]
            let before = text[..<split.lowerBound]
            if before.utf8.contains(where: { $0 != 0x20 }), let target = catalog.language(named: name) {
                return RootRequest(text: String(before), target: target)
            }
        }
        return RootRequest(text: String(text), target: nil)
    }

    /// Where the keyword ends, when the query starts with it, compared without case.
    private static func end(of keyword: [UInt8], in query: String) -> String.Index? {
        let bytes = query.utf8
        var index = bytes.startIndex
        for expected in keyword {
            guard index != bytes.endIndex else { return nil }
            let byte = bytes[index]
            guard expected == 0x20 ? byte == 0x20 : byte | 0x20 == expected else { return nil }
            index = bytes.index(after: index)
        }
        return index
    }

    /// The last " to " in the text, compared without case, as a range of the text.
    private static func lastTo(in text: Substring) -> Range<Substring.Index>? {
        let bytes = text.utf8
        guard bytes.count > to.count else { return nil }
        var end = bytes.endIndex
        while end != bytes.startIndex {
            var start = end
            var matched = true
            for expected in to.reversed() {
                guard start != bytes.startIndex else {
                    matched = false
                    break
                }
                start = bytes.index(before: start)
                let byte = bytes[start]
                if expected == 0x20 ? byte != 0x20 : byte | 0x20 != expected {
                    matched = false
                    break
                }
            }
            if matched { return start..<end }
            end = bytes.index(before: end)
        }
        return nil
    }
}

/// One translation root search asks for: the text and the language named after "to", if any.
nonisolated struct RootRequest: Hashable, Sendable {
    let text: String
    let target: LanguageTag?
}
