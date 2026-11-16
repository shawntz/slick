import Foundation
import KitTemplates

/// Turns another app's placeholders into this feature's, and notes the ones that change meaning.
///
/// Raycast writes the same grammar as Kit's templates, so its text stays as it is. Alfred writes
/// `{clipboard}`, `{clipboard:1}`, `{date}`, `{time}`, `{datetime}`, `{cursor}` and `{random:UUID}`,
/// which become Kit's own. Every other placeholder of the other app stays as literal text, and the
/// result says so, because the user would expect it to fill in. Braces that neither app fills, such
/// as code or JSON, pass through untouched and unnoticed, since they mean the same in both.
nonisolated enum PlaceholderMapping {
    struct Result: Hashable, Sendable {
        var text: String
        /// Placeholders the other app fills that stay as typed here, such as `{browser-tab}`.
        var keptAsTyped: [String] = []
        /// Braces the other app kept as typed that fill in here, such as `{selection}` in a snippet
        /// from Alfred.
        var nowFilled: [String] = []
    }

    /// The names Kit's templates fill. Kept in step with `TemplateParser.names`.
    static let kitNames: Set<String> = [
        "clipboard", "selection", "date", "time", "datetime", "day", "uuid", "cursor", "argument", "snippet",
    ]
    /// Raycast's placeholders that Kit lacks.
    static let raycastOnlyNames: Set<String> = ["browser-tab"]
    /// The names Alfred's placeholders start with, as far as this feature knows them.
    static let alfredNames: Set<String> = [
        "clipboard", "cursor", "date", "datetime", "random", "snippet", "time", "var",
    ]

    /// Raycast's text, and the placeholders Raycast would fill that stay as typed here.
    static func raycast(_ text: String) -> Result {
        map(text) { token, body in
            if isKitPlaceholder(token) { return .keep }
            let name = leadingName(body)
            return kitNames.contains(name) || raycastOnlyNames.contains(name) ? .keptAsTyped : .plain
        }
    }

    /// Alfred's text with its placeholders in Kit's grammar.
    static func alfred(_ text: String) -> Result {
        map(text) { token, body in
            if let replacement = alfredReplacement(body) { return .replace(replacement) }
            if isKitPlaceholder(token) { return .nowFilled }
            let name = leadingName(body)
            return alfredNames.contains(name) || kitNames.contains(name) ? .keptAsTyped : .plain
        }
    }

    /// Kit's form of one of Alfred's placeholders, or nil.
    static func alfredReplacement(_ body: Substring) -> String? {
        switch body {
        case "clipboard", "date", "time", "datetime", "cursor":
            return "{" + body + "}"
        default:
            break
        }
        if body.lowercased() == "random:uuid" { return "{uuid}" }
        let clipboard = "clipboard:"
        if body.hasPrefix(clipboard) {
            let digits = body.dropFirst(clipboard.count)
            if (1...3).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                let offset = Int(digits)
            {
                return offset == 0 ? "{clipboard}" : "{clipboard offset=\(offset)}"
            }
        }
        return nil
    }

    // MARK: Scanning

    private enum Decision {
        /// A placeholder Kit fills the same way.
        case keep
        /// Kit's form of the other app's placeholder.
        case replace(String)
        /// The other app fills it; Kit leaves it as typed.
        case keptAsTyped
        /// The other app leaves it as typed; Kit fills it.
        case nowFilled
        /// Braces that mean nothing to either app.
        case plain
    }

    /// Walks the text the way Kit's parser does: a placeholder runs from `{` to the next `}` on the
    /// same line, skipping quoted strings, with no `{` inside.
    private static func map(_ text: String, decide: (_ token: String, _ body: Substring) -> Decision) -> Result {
        var result = Result(text: "")
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "{", let close = closingBrace(in: text, after: index) else {
                output.append(text[index])
                index = text.index(after: index)
                continue
            }
            let end = text.index(after: close)
            let token = String(text[index..<end])
            switch decide(token, text[text.index(after: index)..<close]) {
            case .keep:
                output += token
                index = end
            case .replace(let replacement):
                output += replacement
                index = end
            case .keptAsTyped:
                output += token
                if !result.keptAsTyped.contains(token) { result.keptAsTyped.append(token) }
                index = end
            case .nowFilled:
                output += token
                if !result.nowFilled.contains(token) { result.nowFilled.append(token) }
                index = end
            case .plain:
                // As Kit's parser does, look for a placeholder from the next character on.
                output.append("{")
                index = text.index(after: index)
            }
        }
        // Mistakes Kit finds only in context, such as a fourth argument, stay as typed too.
        let template = Template(output)
        for issue in template.issues {
            let token = substring(of: output, utf16: issue.range)
            if !result.keptAsTyped.contains(token) { result.keptAsTyped.append(token) }
        }
        result.text = output
        return result
    }

    /// The matching `}` as Kit's parser finds it: quoted strings are skipped, and a line break or a
    /// second `{` ends the search.
    private static func closingBrace(in text: String, after open: String.Index) -> String.Index? {
        var index = text.index(after: open)
        var inQuotes = false
        while index < text.endIndex {
            let character = text[index]
            if inQuotes {
                if character == "\\" {
                    index = text.index(after: index)
                    guard index < text.endIndex else { return nil }
                } else if character == "\"" {
                    inQuotes = false
                } else if character.isNewline {
                    return nil
                }
            } else {
                switch character {
                case "\"": inQuotes = true
                case "}": return index
                case "{": return nil
                default: if character.isNewline { return nil }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// True when Kit reads the token alone as one placeholder without a mistake.
    private static func isKitPlaceholder(_ token: String) -> Bool {
        let template = Template(token)
        return template.issues.isEmpty && template.placeholders.count == 1
    }

    /// The word a placeholder starts with, lowercased: letters, digits and "-".
    static func leadingName(_ body: Substring) -> String {
        let trimmed = body.drop { $0 == " " || $0 == "\t" }
        let name = trimmed.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        return name.lowercased()
    }

    private static func substring(of text: String, utf16 range: Range<Int>) -> String {
        let utf16 = text.utf16
        guard range.lowerBound >= 0, range.upperBound <= utf16.count else { return "" }
        let start = utf16.index(utf16.startIndex, offsetBy: range.lowerBound)
        let end = utf16.index(utf16.startIndex, offsetBy: range.upperBound)
        return String(text[start..<end])
    }
}
