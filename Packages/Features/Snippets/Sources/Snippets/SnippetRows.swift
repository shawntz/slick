import Foundation
import Kit
import KitTemplates

/// Rows, sections and details for snippets, built off the main thread from a snapshot of the
/// library.
nonisolated enum SnippetRows {
    /// A filter option ID that shows every snippet.
    static let allOption = "all"
    /// Prefix of the filter option ID for one collection.
    static let collectionOptionPrefix = "collection:"
    /// How much of a snippet's text search matches, besides its name, keyword and collection.
    static let searchableTextLength = 300
    static let previewLength = 80

    /// The list's sections: Pinned, then snippets without a collection, then one section per
    /// collection. With a collection chosen, only its snippets show.
    @concurrent static func sections(
        _ index: LibraryIndex, filter: String?, prefix: String, order: SnippetOrder, usage: any UsageService
    ) async -> [ListSection] {
        let scores = usage.frecency(namespace: SnippetIDs.namespace)
        let chosen = filter.flatMap(collection(fromOption:))
        var pinned: [Row] = []
        var loose: [Row] = []
        var byCollection: [String: [Row]] = [:]
        for snippet in ordered(index, order: order, scores: scores) {
            if let chosen, snippet.collection != chosen { continue }
            let row = row(snippet, prefix: prefix, rank: scores[SnippetIDs.row(snippet.id)] ?? 0)
            if snippet.isPinned {
                pinned.append(row)
            } else if let collection = snippet.collection {
                byCollection[collection, default: []].append(row)
            } else {
                loose.append(row)
            }
        }
        var sections = [
            ListSection(Strings.pinnedSection, id: "pinned", rows: pinned),
            ListSection(Strings.snippetsSection, id: "snippets", rows: loose),
        ]
        for collection in index.collections {
            sections.append(
                ListSection(collection, id: collectionOptionPrefix + collection, rows: byCollection[collection] ?? []))
        }
        return sections.filter { !$0.rows.isEmpty }
    }

    /// Every snippet as a root search row.
    @concurrent static func catalog(_ index: LibraryIndex, prefix: String, usage: any UsageService) async -> [Row] {
        let scores = usage.frecency(namespace: SnippetIDs.namespace)
        return index.snippets.map { row($0, prefix: prefix, rank: scores[SnippetIDs.row($0.id)] ?? 0) }
    }

    /// The dropdown of collections. Nil when there are none.
    static func filter(_ index: LibraryIndex) -> FilterDropdown? {
        guard !index.collections.isEmpty else { return nil }
        let options =
            [FilterOption(id: allOption, title: Strings.allSnippets)]
            + index.collections.map {
                FilterOption(id: collectionOptionPrefix + $0, title: $0, icon: .symbol("folder"))
            }
        return FilterDropdown(title: Strings.collectionFilter, options: options, defaultID: allOption)
    }

    static func collection(fromOption id: String) -> String? {
        id.hasPrefix(collectionOptionPrefix) ? String(id.dropFirst(collectionOptionPrefix.count)) : nil
    }

    static func row(_ snippet: Snippet, prefix: String, rank: Double) -> Row {
        let keyword = snippet.typedKeyword(prefix: prefix)
        var keywords: [String] = []
        if let keyword { keywords.append(keyword) }
        if let collection = snippet.collection { keywords.append(collection) }
        keywords.append(String(snippet.text.prefix(searchableTextLength)))
        return Row(
            id: SnippetIDs.row(snippet.id), title: snippet.name, subtitle: preview(snippet.text),
            icon: .symbol(snippet.isPinned ? "pin" : "text.quote"), accessories: keyword.map { [.tag($0)] } ?? [],
            keywords: keywords, rankHint: rank, memory: .learnOnly)
    }

    /// The first line with text, its white space collapsed, cut to fit a subtitle.
    static func preview(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) } ?? ""
        let words = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.count > previewLength ? String(words.prefix(previewLength - 1)) + "…" : words
    }

    private static func ordered(_ index: LibraryIndex, order: SnippetOrder, scores: [ItemID: Double]) -> [Snippet] {
        let byName = index.byName
        switch order {
        case .name:
            return byName
        case .frequency:
            let ranked = byName.enumerated().map { (position: $0.offset, snippet: $0.element) }
            return ranked.sorted { lhs, rhs in
                let left = scores[SnippetIDs.row(lhs.snippet.id)] ?? 0
                let right = scores[SnippetIDs.row(rhs.snippet.id)] ?? 0
                return left != right ? left > right : lhs.position < rhs.position
            }
            .map(\.snippet)
        }
    }
}

/// The detail pane for one snippet.
nonisolated enum SnippetDetail {
    @concurrent static func make(_ snippet: Snippet, index: LibraryIndex, prefix: String, uses: Int) async -> Detail {
        let template = Template(snippet.text)
        var metadata: [MetadataItem] = []
        if let keyword = snippet.typedKeyword(prefix: prefix) {
            metadata.append(.label(Strings.keywordLabel, value: keyword))
            metadata.append(
                .label(
                    Strings.expansionLabel, value: snippet.expands ? Strings.expandsValue : Strings.doesNotExpandValue))
        }
        if let collection = snippet.collection {
            metadata.append(.label(Strings.collectionLabel, value: collection, icon: .symbol("folder")))
        }
        var names: [String] = []
        for placeholder in template.placeholders where !names.contains(Strings.placeholderTag(placeholder.kind)) {
            names.append(Strings.placeholderTag(placeholder.kind))
        }
        if !names.isEmpty {
            metadata.append(.tags(Strings.placeholdersLabel, names.map { Tag($0, color: .purple) }))
        }
        if let issue = template.issues.first {
            metadata.append(
                .label(
                    Strings.problemLabel, value: issue.message, icon: .symbol("exclamationmark.triangle", tint: .orange)
                ))
        }
        let includers = index.includers(of: snippet.name)
        if !includers.isEmpty {
            metadata.append(.label(Strings.includedByLabel, value: includers.joined(separator: ", ")))
        }
        metadata.append(.separator)
        metadata.append(.label(Strings.usedLabel, value: Strings.useCount(uses)))
        if let created = snippet.created { metadata.append(.date(Strings.createdLabel, created)) }
        if let modified = snippet.modified { metadata.append(.date(Strings.modifiedLabel, modified)) }
        return Detail(.markdown(marked(template)), metadata: metadata)
    }

    /// The snippet's text as Markdown, with each placeholder set in code so it stands out. Each line
    /// of the text is a paragraph of its own, so line breaks show.
    static func marked(_ template: Template) -> String {
        var lines: [String] = []
        var line = LineWriter()
        for segment in template.segments {
            switch segment {
            case .text(let literal):
                for (position, part) in literal.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    if position > 0 {
                        lines.append(line.text)
                        line = LineWriter()
                    }
                    line.appendLiteral(part)
                }
            case .placeholder(let placeholder):
                line.appendCode(source(of: placeholder, in: template.source))
            }
        }
        lines.append(line.text)
        return lines.map { $0.allSatisfy(\.isWhitespace) ? "" : $0 }.joined(separator: "\n\n")
    }

    private static func source(of placeholder: Placeholder, in text: String) -> String {
        let utf16 = text.utf16
        let start = utf16.index(utf16.startIndex, offsetBy: placeholder.sourceRange.lowerBound)
        let end = utf16.index(utf16.startIndex, offsetBy: placeholder.sourceRange.upperBound)
        return String(text[start..<end])
    }

    /// Builds one line of Markdown, escaping what the text would otherwise mean as markup.
    private struct LineWriter {
        private(set) var text = ""
        /// True until the first character that is not white space.
        private var atStart = true
        /// True while everything since the start is digits, which a "." or ")" would turn into a
        /// numbered list.
        private var onlyDigits = true

        mutating func appendLiteral(_ part: Substring) {
            for character in part where character != "\r" {
                if atStart, character == " " || character == "\t" {
                    text.append(character)
                    continue
                }
                let escapesAnywhere = "\\`*_[]#<>".contains(character)
                let escapesAtStart = atStart && "-+=~|".contains(character)
                let endsNumber = !atStart && onlyDigits && (character == "." || character == ")")
                if escapesAnywhere || escapesAtStart || endsNumber { text.append("\\") }
                text.append(character)
                onlyDigits = onlyDigits && character.isASCII && character.isNumber
                atStart = false
            }
        }

        mutating func appendCode(_ code: String) {
            let longestRun = code.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
            let fence = String(repeating: "`", count: longestRun + 1)
            let padding = code.hasPrefix("`") || code.hasSuffix("`") ? " " : ""
            text += fence + padding + code + padding + fence
            atStart = false
            onlyDigits = false
        }
    }
}
