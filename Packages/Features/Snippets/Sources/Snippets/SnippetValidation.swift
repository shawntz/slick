import Foundation
import Kit
import KitTemplates

/// What is wrong with a draft, by form field, in words that say how to fix it. Pure, so it runs off
/// the main thread against a snapshot of the library.
nonisolated enum SnippetValidation {
    /// The longest text a snippet may hold, as in other launchers.
    static let maximumLength = 65_536

    /// The expansion settings that decide whether one keyword hides another.
    struct Rules: Hashable, Sendable {
        var prefix: String
        var trigger: ExpansionTrigger
    }

    @concurrent static func check(_ draft: SnippetDraft, editing id: String?, index: LibraryIndex, rules: Rules)
        async -> [String: FieldError]
    {
        problems(draft, editing: id, index: index, rules: rules)
    }

    static func problems(_ draft: SnippetDraft, editing id: String?, index: LibraryIndex, rules: Rules) -> [String:
        FieldError]
    {
        var problems: [String: FieldError] = [:]
        let others = index.snippets.filter { $0.id != id }
        let name = draft.cleanName
        if !name.isEmpty, others.contains(where: { $0.name == name }) {
            problems[FormFields.name] = FieldError(Strings.nameTaken)
        }
        if let problem = textProblem(draft.text, name: name, others: others) {
            problems[FormFields.text] = problem
        }
        if let problem = keywordProblem(draft.keyword, expands: draft.expands, others: others, rules: rules) {
            problems[FormFields.keyword] = problem
        }
        return problems
    }

    private static func textProblem(_ text: String, name: String, others: [Snippet]) -> FieldError? {
        if text.count > maximumLength { return FieldError(Strings.textTooLong(maximumLength)) }
        let template = Template(text)
        // The range lets the editor select the broken placeholder.
        if let issue = template.issues.first {
            return FieldError(Strings.placeholderProblem(issue.message), range: issue.range)
        }
        var cursors = 0
        for placeholder in template.placeholders {
            switch placeholder.kind {
            case .snippet(let included) where included == name:
                return FieldError(Strings.includesItself, range: placeholder.sourceRange)
            case .snippet(let included) where !others.contains(where: { $0.name == included }):
                return FieldError(Strings.noSnippetNamed(included), range: placeholder.sourceRange)
            case .cursor:
                cursors += 1
                if cursors > 1 { return FieldError(Strings.cursorTwice, range: placeholder.sourceRange) }
            default:
                break
            }
        }
        return nil
    }

    /// What is wrong with a keyword, or nil. Import uses it too, so a file cannot bring in a keyword
    /// the editor would refuse, such as one letter that would expand all through ordinary typing.
    static func keywordProblem(_ keyword: String, expands: Bool, others: [Snippet], rules: Rules) -> FieldError? {
        let raw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if raw.contains(where: \.isWhitespace) { return FieldError(Strings.keywordHasSpace) }
        let typed = rules.prefix + raw
        if typed.count < 2 { return FieldError(Strings.keywordTooShort) }
        if let other = others.first(where: { $0.keyword == raw }) {
            return FieldError(Strings.keywordTaken(by: other.name))
        }
        // When keywords expand at once, a keyword that starts another hides it.
        guard rules.trigger == .immediately, expands else { return nil }
        for other in others where other.expands {
            guard let otherTyped = other.typedKeyword(prefix: rules.prefix) else { continue }
            if typed.hasPrefix(otherTyped) {
                return FieldError(Strings.keywordShadowed(by: other.name, keyword: otherTyped))
            }
            if otherTyped.hasPrefix(typed) {
                return FieldError(Strings.keywordShadows(other.name, keyword: otherTyped))
            }
        }
        return nil
    }
}

/// The editor form's field IDs.
nonisolated enum FormFields {
    static let name = "name"
    static let text = "text"
    static let keyword = "keyword"
    static let collection = "collection"
    static let expands = "expands"
}
