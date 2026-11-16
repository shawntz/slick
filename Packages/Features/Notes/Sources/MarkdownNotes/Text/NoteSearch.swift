import Darwin
import Foundation
import Kit

/// What the user typed on Search Notes, and how it is matched. Pure, so it runs on any thread.
///
/// Every word must appear, in the title or in the text, ignoring case, accents and width. Text is
/// folded once when a note is read, and a search compares bytes, so 5,000 notes take a few
/// milliseconds.
nonisolated struct NoteQuery: Hashable, Sendable {
    /// The most words a query uses, and the longest word.
    static let maximumWords = 16
    static let maximumWordLength = 200

    /// The words as typed.
    let words: [String]
    /// The words folded as note text is.
    let folded: [String]

    init(_ text: String) {
        let words = text.prefix(4_000).split { character in
            character.isWhitespace || character.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }
        .prefix(Self.maximumWords).map { String($0.prefix(Self.maximumWordLength)) }
        let folded = words.map(NoteSearch.fold)
        var kept: [(String, String)] = []
        for (word, fold) in zip(words, folded) where !fold.isEmpty && !kept.contains(where: { $0.1 == fold }) {
            kept.append((word, fold))
        }
        self.words = kept.map(\.0)
        self.folded = kept.map(\.1)
    }

    var isEmpty: Bool { words.isEmpty }
}

nonisolated enum NoteSearch {
    /// Text folded for matching: case, accents and width removed, in contiguous UTF-8.
    static func fold(_ text: some StringProtocol) -> String {
        var folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        folded.makeContiguousUTF8()
        return folded
    }

    /// True when the folded needle appears in the folded haystack, compared as bytes.
    static func contains(_ haystack: String, _ needle: String) -> Bool {
        var haystack = haystack
        var needle = needle
        return haystack.withUTF8 { hay in
            needle.withUTF8 { word in
                guard !word.isEmpty else { return true }
                guard let hayStart = hay.baseAddress, let wordStart = word.baseAddress, hay.count >= word.count else {
                    return false
                }
                return memmem(hayStart, hay.count, wordStart, word.count) != nil
            }
        }
    }

    /// The byte offset of the folded needle in the folded haystack.
    static func offset(of needle: String, in haystack: String) -> Int? {
        var haystack = haystack
        var needle = needle
        return haystack.withUTF8 { hay in
            needle.withUTF8 { word -> Int? in
                guard let hayStart = hay.baseAddress, let wordStart = word.baseAddress, !word.isEmpty,
                    hay.count >= word.count, let found = memmem(hayStart, hay.count, wordStart, word.count)
                else { return nil }
                return UnsafeRawPointer(found) - UnsafeRawPointer(hayStart)
            }
        }
    }

    /// Where each word appears in a title, ignoring case, accents and width, in UTF-16 offsets and
    /// merged where they touch.
    static func highlights(_ query: NoteQuery, in title: String) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for word in query.words {
            var searchStart = title.startIndex
            while let found = title.range(of: word, options: searchOptions, range: searchStart..<title.endIndex) {
                let start = title.utf16.distance(from: title.startIndex, to: found.lowerBound)
                ranges.append(start..<(start + title[found].utf16.count))
                searchStart = found.upperBound
                if ranges.count > 64 { break }
            }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// One line of the note around the first place the first word that is not in the title appears,
    /// such as "…the budget for the trip…". Nil when it cannot be found.
    static func snippet(_ query: NoteQuery, foldedTitle: String, text: NoteSearchText) -> String? {
        let pairs = Array(zip(query.words, query.folded))
        guard let (word, folded) = pairs.first(where: { !contains(foldedTitle, $0.1) }) ?? pairs.first,
            let offset = offset(of: folded, in: text.folded)
        else { return nil }
        // Folding keeps line breaks, so the match lies on the same line of the original text.
        let line = lineNumber(atByte: offset, in: text.folded)
        guard let original = self.line(line, of: text.original) else { return nil }
        let window = original.prefix(20_000)
        let found = window.range(of: word, options: searchOptions)
        let start = found?.lowerBound ?? window.startIndex
        let lead = window[..<start].suffix(snippetLead)
        let tail = window[start...].prefix(snippetLength)
        var snippet = String(lead) + String(tail)
        snippet = snippet.trimmingCharacters(in: .whitespaces)
        if lead.startIndex > window.startIndex { snippet = "…" + snippet }
        if tail.endIndex < original.endIndex { snippet += "…" }
        return DisplayText.oneLine(snippet)
    }

    /// Characters a snippet shows before the match, and in all after its start.
    static let snippetLead = 30
    static let snippetLength = 90

    static let searchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// How many line breaks come before a byte offset.
    private static func lineNumber(atByte offset: Int, in text: String) -> Int {
        var text = text
        return text.withUTF8 { bytes in
            var count = 0
            for index in 0..<min(offset, bytes.count) where bytes[index] == UInt8(ascii: "\n") { count += 1 }
            return count
        }
    }

    /// The text of one line, counted from zero.
    private static func line(_ number: Int, of text: String) -> Substring? {
        let utf8 = text.utf8
        var start = utf8.startIndex
        var remaining = number
        while remaining > 0 {
            guard let newline = utf8[start...].firstIndex(of: UInt8(ascii: "\n")) else { return nil }
            start = utf8.index(after: newline)
            remaining -= 1
        }
        let end = utf8[start...].firstIndex(of: UInt8(ascii: "\n")) ?? utf8.endIndex
        return text[start..<end]
    }
}
