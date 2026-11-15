import Foundation

/// One snippet in an import or export file.
///
/// The file is a JSON array of objects with `name`, `text` and an optional `keyword`, the shape
/// other launchers export, so files move both ways. This feature also writes `collection`,
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

    init(_ snippet: Snippet) {
        self.init(
            name: snippet.name, text: snippet.text, keyword: snippet.keyword, collection: snippet.collection,
            expands: snippet.expands, isPinned: snippet.isPinned)
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

/// What an import did, for the toast.
nonisolated struct ImportSummary: Hashable, Sendable {
    var added = 0
    /// Entries equal to a snippet the user already has, by name, text and keyword.
    var duplicates = 0
    /// Entries whose keyword another snippet already uses. Nothing is overwritten.
    var keywordClashes = 0
    /// Entries without a name or text, or that are not objects at all.
    var incomplete = 0
    /// Entries added under a new name because theirs was taken.
    var renamed = 0
    /// Entries added without their keyword, because the editor would refuse it: too short, with a
    /// space, or one that would keep another keyword from expanding.
    var keywordsLeftOut = 0
}

/// Reading import files and merging them into the library.
nonisolated enum SnippetImport {
    /// The entries in a file. Throws when the file cannot be read or is not JSON of the right shape.
    @concurrent static func read(_ url: URL) async throws -> [TransferEntry] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ImportFile.self, from: data).entries
    }

    /// The library with the entries added, and what happened to each.
    ///
    /// Rules: an entry needs a name and text. An entry equal to an existing snippet is skipped. An
    /// entry whose keyword is taken is skipped, so nothing the user has is changed. An entry whose
    /// keyword the editor would refuse is added without it. An entry whose name is taken is added
    /// with a number after its name.
    static func merge(
        _ entries: [TransferEntry], into existing: [Snippet], at date: Date, rules: SnippetValidation.Rules
    ) -> (snippets: [Snippet], summary: ImportSummary) {
        struct Identity: Hashable {
            var name: String
            var text: String
            var keyword: String?
        }
        var snippets = existing
        var identities = Set(existing.map { Identity(name: $0.name, text: $0.text, keyword: $0.keyword) })
        var names = Set(existing.map(\.name))
        var keywords = Set(existing.compactMap(\.keyword))
        var summary = ImportSummary()
        for entry in entries {
            guard let name = Snippet.clean(entry.name), let text = entry.text,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                summary.incomplete += 1
                continue
            }
            var keyword = Snippet.clean(entry.keyword)
            guard identities.insert(Identity(name: name, text: text, keyword: keyword)).inserted else {
                summary.duplicates += 1
                continue
            }
            if let typed = keyword, keywords.contains(typed) {
                summary.keywordClashes += 1
                continue
            }
            let expands = entry.expands ?? true
            if let typed = keyword,
                SnippetValidation.keywordProblem(typed, expands: expands, others: snippets, rules: rules) != nil
            {
                keyword = nil
                summary.keywordsLeftOut += 1
            }
            var finalName = name
            if names.contains(name) {
                finalName = uniqueName(name, taken: names)
                summary.renamed += 1
            }
            names.insert(finalName)
            if let keyword { keywords.insert(keyword) }
            snippets.append(
                Snippet(
                    id: UUID().uuidString, name: finalName, text: text, keyword: keyword, collection: entry.collection,
                    expands: expands, isPinned: entry.isPinned ?? false, created: date, modified: date))
            summary.added += 1
        }
        return (snippets, summary)
    }

    /// "Name 2", "Name 3" and so on: the first that is free.
    static func uniqueName(_ name: String, taken: Set<String>) -> String {
        var number = 2
        while taken.contains(Strings.numberedName(name, number)) { number += 1 }
        return Strings.numberedName(name, number)
    }
}

/// An import file: an array of entries, or an object holding one under `snippets`.
private nonisolated struct ImportFile: Decodable {
    private enum CodingKeys: String, CodingKey {
        case snippets
    }

    /// Decodes nothing, so an entry that is not an object can be stepped over.
    private struct Skip: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    var entries: [TransferEntry] = []

    init(from decoder: any Decoder) throws {
        var array: any UnkeyedDecodingContainer
        if let top = try? decoder.unkeyedContainer() {
            array = top
        } else {
            array = try decoder.container(keyedBy: CodingKeys.self).nestedUnkeyedContainer(forKey: .snippets)
        }
        while !array.isAtEnd {
            if let entry = try? array.decode(TransferEntry.self) {
                entries.append(entry)
            } else {
                // Not an object: step over it and count it as incomplete.
                _ = try array.decode(Skip.self)
                entries.append(TransferEntry())
            }
        }
    }
}
