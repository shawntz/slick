import Foundation
import Kit

/// One snippet in an import or export file.
///
/// The file is a JSON array of objects with `name`, `text` and an optional `keyword`, the shape
/// Raycast exports and imports, so files move both ways. This feature also writes `collection`,
/// `expands` and `pinned`, and reads them when present. An object `{"snippets": [...]}`, such as
/// a copy of the feature's own data file, imports too.
nonisolated struct TransferEntry: Hashable, Sendable {
    var name: String?
    var text: String?
    var keyword: String?
    var collection: String?
    var expands: Bool?
    var isPinned: Bool?

    init(
        name: String? = nil, text: String? = nil, keyword: String? = nil, collection: String? = nil,
        expands: Bool? = nil, isPinned: Bool? = nil
    ) {
        self.name = name
        self.text = text
        self.keyword = keyword
        self.collection = collection
        self.expands = expands
        self.isPinned = isPinned
    }

    /// The snippet as an export writes it. The keyword is written as it is typed, with the shared
    /// prefix, because other apps have no prefix of their own.
    init(_ snippet: Snippet, prefix: String = "") {
        self.init(
            name: snippet.name, text: snippet.text, keyword: snippet.typedKeyword(prefix: prefix),
            collection: snippet.collection, expands: snippet.expands, isPinned: snippet.isPinned)
    }
}

extension TransferEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case name, text, keyword, collection, expands, pinned
    }

    /// Reads what it can. A field of the wrong type counts as missing, so one odd entry does not
    /// stop the rest of the file.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try? container.decodeIfPresent(String.self, forKey: .name),
            text: try? container.decodeIfPresent(String.self, forKey: .text),
            keyword: try? container.decodeIfPresent(String.self, forKey: .keyword),
            collection: try? container.decodeIfPresent(String.self, forKey: .collection),
            expands: try? container.decodeIfPresent(Bool.self, forKey: .expands),
            isPinned: try? container.decodeIfPresent(Bool.self, forKey: .pinned))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(keyword, forKey: .keyword)
        try container.encodeIfPresent(collection, forKey: .collection)
        try container.encodeIfPresent(expands, forKey: .expands)
        try container.encodeIfPresent(isPinned, forKey: .pinned)
    }
}

/// An entry read from an import file, with what the reader noticed about its placeholders.
nonisolated struct ImportedEntry: Hashable, Sendable {
    var entry: TransferEntry
    /// Placeholders the other app fills that stay as typed here, such as `{browser-tab}`.
    var keptAsTyped: [String] = []
    /// Braces the other app kept as typed that fill in here, such as `{selection}` from Alfred.
    var nowFilled: [String] = []

    init(_ entry: TransferEntry, keptAsTyped: [String] = [], nowFilled: [String] = []) {
        self.entry = entry
        self.keptAsTyped = keptAsTyped
        self.nowFilled = nowFilled
    }

    /// True when a placeholder behaves differently here than in the app the file came from.
    var isFlagged: Bool { !keptAsTyped.isEmpty || !nowFilled.isEmpty }
}

/// What an import does, entry by entry, decided against the snippets the user has.
nonisolated struct ImportPlan: Hashable, Sendable {
    enum Outcome: Hashable, Sendable {
        /// Added as it is.
        case add
        /// Added, but without the keyword the file gives it.
        case addWithoutKeyword(KeywordLeftOut)
        /// Skipped: a snippet with the same keyword and text exists, by this name.
        case duplicate(of: String)
        /// Skipped: the entry cannot be a snippet.
        case notValid(NotValid)
    }

    enum KeywordLeftOut: Hashable, Sendable {
        /// Another snippet, with different text, has the keyword.
        case taken(keyword: String, by: String)
        /// The editor would refuse the keyword, for this reason.
        case refused(keyword: String, reason: String)
    }

    enum NotValid: Hashable, Sendable {
        case noName
        case noText
        case nameTooLong
        case textTooLong
    }

    struct Item: Hashable, Sendable {
        var outcome: Outcome
        /// The snippet as it will be saved, when the outcome adds one.
        var snippet: Snippet?
        /// The saved name, else the name in the file, else the entry's place in the file.
        var title: String
        /// The name in the file, when the snippet is saved under another because that one is taken.
        var renamedFrom: String?
        /// The text and keyword as the file gives them, after mapping, for the detail.
        var text: String
        var keyword: String?
        var keptAsTyped: [String]
        var nowFilled: [String]
    }

    var items: [Item]
    var summary: ImportSummary

    /// The snippets to add, in file order.
    var snippets: [Snippet] { items.compactMap(\.snippet) }
}

/// What an import did, for the toast.
nonisolated struct ImportSummary: Hashable, Sendable {
    /// Every snippet added, with or without its keyword.
    var added = 0
    /// Snippets added without the keyword the file gives them.
    var withoutKeyword = 0
    /// Entries with the same keyword and text as a snippet the user already has, or as one earlier
    /// in the file.
    var duplicates = 0
    /// Entries without a name or text, too long, or not objects at all.
    var notValid = 0
    /// Snippets added under a new name because theirs was taken.
    var renamed = 0
    /// Snippets added whose placeholders behave differently here.
    var flagged = 0
}

/// Planning an import and merging it into the library.
nonisolated enum SnippetImport {
    /// The longest name an imported snippet may have.
    static let maximumNameLength = 256

    /// ``plan(_:existing:at:rules:)`` off the main thread: a file can hold ten thousand entries.
    @concurrent static func planInBackground(
        _ entries: [ImportedEntry], existing: [Snippet], at date: Date, rules: SnippetValidation.Rules
    ) async -> ImportPlan {
        plan(entries, existing: existing, at: date, rules: rules)
    }

    /// What each entry becomes. Nothing the user has is changed.
    ///
    /// Rules, in order: an entry needs a name and text within the editor's limits. An entry with the
    /// same keyword and text as a snippet the user has, or as one added earlier in the file, is a
    /// duplicate. So is one whose keyword is taken while a snippet without a keyword has its name and
    /// text, which is how an earlier import of it was saved. An entry whose keyword another snippet
    /// has is added without it, and so is one whose keyword the editor would refuse. An entry whose
    /// name is taken is added with a number after its name. A keyword that starts with the shared
    /// prefix loses it, so it is typed as before.
    static func plan(_ entries: [ImportedEntry], existing: [Snippet], at date: Date, rules: SnippetValidation.Rules)
        -> ImportPlan
    {
        var byText: [String: [Snippet]] = [:]
        var byKeyword: [String: String] = [:]
        var expanding = ExpandingKeywords()
        for snippet in existing {
            byText[snippet.text, default: []].append(snippet)
            if let keyword = snippet.keyword, byKeyword[keyword] == nil { byKeyword[keyword] = snippet.name }
            if snippet.expands, let typed = snippet.typedKeyword(prefix: rules.prefix) {
                expanding.insert(typed, name: snippet.name)
            }
        }
        var names = Set(existing.map(\.name))
        var plan = ImportPlan(items: [], summary: ImportSummary())
        for (position, imported) in entries.enumerated() {
            let entry = imported.entry
            let name = ImportText.line(entry.name)
            let text = entry.text.map(ImportText.text) ?? ""
            let keyword = fileKeyword(entry.keyword, prefix: rules.prefix)
            var item = ImportPlan.Item(
                outcome: .add, snippet: nil, title: name ?? Strings.entryTitle(position + 1), renamedFrom: nil,
                text: text, keyword: keyword, keptAsTyped: imported.keptAsTyped, nowFilled: imported.nowFilled)
            if let problem = problem(name: name, text: text) {
                item.outcome = .notValid(problem)
                plan.summary.notValid += 1
                plan.items.append(item)
                continue
            }
            guard let name else { continue }
            if let earlier = duplicate(name: name, text: text, keyword: keyword, among: byText[text] ?? []) {
                item.outcome = .duplicate(of: earlier)
                plan.summary.duplicates += 1
                plan.items.append(item)
                continue
            }
            let expands = entry.expands ?? true
            var savedKeyword = keyword
            if let typed = keyword {
                if let holder = byKeyword[typed] {
                    item.outcome = .addWithoutKeyword(.taken(keyword: typed, by: holder))
                } else if !ImportText.isTypeable(typed) {
                    item.outcome = .addWithoutKeyword(.refused(keyword: typed, reason: Strings.keywordNotTypeable))
                } else if let problem = SnippetValidation.keywordProblem(
                    typed, expands: expands, others: [], rules: rules)
                    ?? (rules.trigger == .immediately && expands ? expanding.problem(rules.prefix + typed) : nil)
                {
                    item.outcome = .addWithoutKeyword(.refused(keyword: typed, reason: problem.message))
                }
                if case .addWithoutKeyword = item.outcome { savedKeyword = nil }
            }
            var savedName = name
            if names.contains(name) {
                savedName = uniqueName(name, taken: names)
                item.renamedFrom = name
                plan.summary.renamed += 1
            }
            names.insert(savedName)
            let snippet = Snippet(
                id: UUID().uuidString, name: savedName, text: text, keyword: savedKeyword,
                collection: ImportText.line(entry.collection), expands: expands, isPinned: entry.isPinned ?? false,
                created: date, modified: date)
            item.snippet = snippet
            item.title = savedName
            if expands, let typed = snippet.typedKeyword(prefix: rules.prefix) {
                expanding.insert(typed, name: savedName)
            }
            // Later entries count this one: by its keyword in the file for duplicates, and by the
            // keyword it is saved with for clashes.
            var recorded = snippet
            recorded.keyword = keyword
            byText[text, default: []].append(recorded)
            if let savedKeyword { byKeyword[savedKeyword] = savedName }
            plan.summary.added += 1
            if case .addWithoutKeyword = item.outcome { plan.summary.withoutKeyword += 1 }
            if imported.isFlagged { plan.summary.flagged += 1 }
            plan.items.append(item)
        }
        return plan
    }

    /// The keywords that expand, as typed, and every shorter start of each, so a new keyword is
    /// checked against all of them in time that grows with its own length rather than with the
    /// library. It finds what ``SnippetValidation/keywordProblem(_:expands:others:rules:)`` finds
    /// when keywords expand at once: one keyword that starts another.
    private struct ExpandingKeywords {
        private var keywords: [String: String] = [:]
        private var starts: [String: (keyword: String, name: String)] = [:]

        mutating func insert(_ typed: String, name: String) {
            if keywords[typed] == nil { keywords[typed] = name }
            var start = ""
            for character in typed.dropLast() {
                start.append(character)
                if starts[start] == nil { starts[start] = (typed, name) }
            }
        }

        func problem(_ typed: String) -> FieldError? {
            var start = ""
            for character in typed.dropLast() {
                start.append(character)
                if let name = keywords[start] { return FieldError(Strings.keywordShadowed(by: name, keyword: start)) }
            }
            guard let owner = starts[typed] else { return nil }
            return FieldError(Strings.keywordShadows(owner.name, keyword: owner.keyword))
        }
    }

    /// The keyword as the file gives it, trimmed, without the shared prefix when it starts with it.
    static func fileKeyword(_ keyword: String?, prefix: String) -> String? {
        guard let keyword = Snippet.clean(keyword) else { return nil }
        guard !prefix.isEmpty, keyword.hasPrefix(prefix), keyword.count > prefix.count else { return keyword }
        return String(keyword.dropFirst(prefix.count))
    }

    private static func problem(name: String?, text: String) -> ImportPlan.NotValid? {
        guard let name else { return .noName }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .noText }
        if name.count > maximumNameLength { return .nameTooLong }
        if text.count > SnippetValidation.maximumLength { return .textTooLong }
        return nil
    }

    /// The name of a snippet this entry duplicates, among those with the same text.
    private static func duplicate(name: String, text: String, keyword: String?, among sameText: [Snippet])
        -> String?
    {
        if let match = sameText.first(where: { $0.keyword == keyword }) { return match.name }
        guard keyword != nil else { return nil }
        return sameText.first { $0.keyword == nil && $0.name == name }?.name
    }

    /// "Name 2", "Name 3" and so on: the first that is free.
    static func uniqueName(_ name: String, taken: Set<String>) -> String {
        var number = 2
        while taken.contains(Strings.numberedName(name, number)) { number += 1 }
        return Strings.numberedName(name, number)
    }
}

/// Cleaning for text that comes from a file the user picked.
nonisolated enum ImportText {
    /// A name or collection on one line: line breaks and other controls become spaces, direction
    /// overrides become U+FFFD, runs of white space become one space and the ends are trimmed. Nil
    /// when nothing is left.
    static func line(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = DisplayText.oneLine(value).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    /// The text without control characters other than tab and line breaks, so a pasted snippet can
    /// never carry an escape sequence into a terminal.
    static func text(_ value: String) -> String {
        guard value.unicodeScalars.contains(where: isDropped) else { return value }
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars where !isDropped(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// False for a keyword with a character nobody types: a control or format character, such as a
    /// direction override, or a line or paragraph separator.
    static func isTypeable(_ keyword: String) -> Bool {
        !keyword.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: true
            default: false
            }
        }
    }

    private static func isDropped(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.properties.generalCategory == .control else { return false }
        return scalar != "\t" && scalar != "\n" && scalar != "\r"
    }
}
