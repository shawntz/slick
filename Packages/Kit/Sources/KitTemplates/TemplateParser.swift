import Foundation

/// Turns template source into segments. See ``Template`` for the grammar.
struct TemplateParser {
    private static let names: Set<String> = [
        "clipboard", "selection", "date", "time", "datetime", "day", "uuid", "cursor", "argument", "snippet",
    ]
    private static let maximumArguments = 3

    private let source: String
    private let shorthands: TemplateShorthands
    private var segments: [Template.Segment] = []
    private var issues: [TemplateIssue] = []
    private var unnamedArguments = 0
    private var argumentKeys: [String] = []

    init(_ source: String, shorthands: TemplateShorthands = []) {
        self.source = source
        self.shorthands = shorthands
    }

    func parse() -> ([Template.Segment], [TemplateIssue]) {
        var parser = self
        parser.run()
        return (parser.segments, parser.issues)
    }

    private mutating func run() {
        var literal = ""
        var index = source.startIndex
        while index < source.endIndex {
            guard source[index] == "{", let close = closingBrace(after: index) else {
                literal.append(source[index])
                index = source.index(after: index)
                continue
            }
            let body = source[source.index(after: index)..<close]
            let end = source.index(after: close)
            let range = offset(of: index)..<offset(of: end)
            switch placeholder(body, range: range) {
            case .some(.success(let placeholder)):
                if !literal.isEmpty { segments.append(.text(literal)) }
                literal = ""
                segments.append(.placeholder(placeholder))
                index = end
            case .some(.failure(let issue)):
                issues.append(issue)
                literal += source[index..<end]
                index = end
            case .none:
                literal.append(source[index])
                index = source.index(after: index)
            }
        }
        if !literal.isEmpty { segments.append(.text(literal)) }
    }

    /// The matching "}" for a "{", skipping quoted strings. Nil at a newline or a nested "{".
    private func closingBrace(after open: String.Index) -> String.Index? {
        var index = source.index(after: open)
        var inQuotes = false
        while index < source.endIndex {
            let character = source[index]
            if inQuotes {
                if character == "\\" {
                    index = source.index(after: index)
                    guard index < source.endIndex else { return nil }
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
            index = source.index(after: index)
        }
        return nil
    }

    private func offset(of index: String.Index) -> Int {
        source.utf16.distance(from: source.startIndex, to: index)
    }

    /// Nil when the body does not start with a known name: the braces are plain text.
    private mutating func placeholder(_ body: Substring, range: Range<Int>) -> Result<Placeholder, TemplateIssue>? {
        var scanner = BodyScanner(body)
        scanner.skipSpaces()
        let name = scanner.word()
        guard Self.names.contains(name) || (name == "query" && shorthands.contains(.query)) else { return nil }
        func issue(_ message: String) -> Result<Placeholder, TemplateIssue> {
            .failure(TemplateIssue(message, range: range))
        }

        var attributes: [(key: String, value: String)] = []
        var modifiers: [TemplateModifier] = []
        while true {
            scanner.skipSpaces()
            if scanner.isAtEnd { break }
            if scanner.consume("|") {
                scanner.skipSpaces()
                let word = scanner.word()
                guard let modifier = TemplateModifier(rawValue: word) else {
                    return issue("unknown modifier \"\(word)\"")
                }
                modifiers.append(modifier)
                continue
            }
            guard modifiers.isEmpty else { return issue("attributes must come before modifiers") }
            let key = scanner.word()
            guard !key.isEmpty, scanner.consume("=") else { return issue("expected key=value in {\(name)}") }
            attributes.append((key, scanner.value()))
        }

        let kind: PlaceholderKind
        switch makeKind(name, attributes) {
        case .success(let made): kind = made
        case .failure(let message): return issue(message.text)
        }
        if case .argument(let argument) = kind, !argumentKeys.contains(argument.key) {
            guard argumentKeys.count < Self.maximumArguments else {
                return issue("a template takes at most \(Self.maximumArguments) arguments")
            }
            argumentKeys.append(argument.key)
        }
        return .success(Placeholder(kind: kind, modifiers: modifiers, sourceRange: range))
    }

    private struct Message: Error {
        let text: String
    }

    private mutating func makeKind(_ name: String, _ attributes: [(key: String, value: String)]) -> Result<
        PlaceholderKind, Message
    > {
        var values: [String: String] = [:]
        for (key, value) in attributes {
            guard values[key] == nil else { return .failure(Message(text: "\(key) is given twice")) }
            values[key] = value
        }
        func allow(_ keys: Set<String>) -> Message? {
            values.keys.first { !keys.contains($0) }.map { Message(text: "{\(name)} has no attribute \"\($0)\"") }
        }
        switch name {
        case "clipboard":
            if let problem = allow(["offset"]) { return .failure(problem) }
            guard let offset = Int(values["offset"] ?? "0"), offset >= 0 else {
                return .failure(Message(text: "offset must be a whole number from 0"))
            }
            return .success(.clipboard(offset: offset))
        case "date", "time", "datetime", "day":
            if let problem = allow(["offset", "format", "locale"]) { return .failure(problem) }
            if values["format"] != nil && values["locale"] != nil {
                return .failure(Message(text: "format and locale cannot be used together"))
            }
            guard let offsets = Self.offsets(values["offset"] ?? "") else {
                return .failure(Message(text: "offset must look like \"+2d -3h\", with units s m h d w M y"))
            }
            let style = DateStyle(rawValue: name) ?? .date
            return .success(
                .date(style, DateOptions(offsets: offsets, format: values["format"], locale: values["locale"])))
        case "argument":
            if let problem = allow(["name", "default", "options"]) { return .failure(problem) }
            let argumentName = values["name"].flatMap { $0.isEmpty ? nil : $0 }
            let key: String
            if let argumentName {
                key = argumentName
            } else {
                unnamedArguments += 1
                key = "#\(unnamedArguments)"
            }
            return .success(
                .argument(
                    TemplateArgument(
                        key: key, name: argumentName, defaultValue: values["default"],
                        options: Self.options(values["options"]))))
        case "query":
            // The short form of {argument name="Query"}: same key, so both share one value.
            if let problem = allow(["default", "options"]) { return .failure(problem) }
            let queryName = TemplateShorthands.queryArgumentName
            return .success(
                .argument(
                    TemplateArgument(
                        key: queryName, name: queryName, defaultValue: values["default"],
                        options: Self.options(values["options"]))))
        case "snippet":
            if let problem = allow(["name"]) { return .failure(problem) }
            guard let snippetName = values["name"], !snippetName.isEmpty else {
                return .failure(Message(text: "{snippet} needs a name"))
            }
            return .success(.snippet(name: snippetName))
        default:
            if let problem = allow([]) { return .failure(problem) }
            switch name {
            case "selection": return .success(.selection)
            case "uuid": return .success(.uuid)
            default: return .success(.cursor)
            }
        }
    }

    /// The choices of a comma-separated `options` attribute, trimmed, without empty ones.
    private static func options(_ text: String?) -> [String] {
        (text ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Parses "+2y +5M -3d". Each step is a sign, digits and a unit with no spaces inside.
    static func offsets(_ text: String) -> [DateOffset]? {
        var result: [DateOffset] = []
        for token in text.split(separator: " ") {
            guard let sign = token.first, sign == "+" || sign == "-", let unitCharacter = token.last,
                let unit = DateOffset.Unit(rawValue: String(unitCharacter)),
                let magnitude = Int(token.dropFirst().dropLast())
            else { return nil }
            result.append(DateOffset(sign == "-" ? -magnitude : magnitude, unit))
        }
        return result
    }
}

/// Reads the inside of one placeholder.
private struct BodyScanner {
    private let text: Substring
    private var index: Substring.Index

    init(_ text: Substring) {
        self.text = text
        self.index = text.startIndex
    }

    var isAtEnd: Bool { index >= text.endIndex }

    mutating func skipSpaces() {
        while index < text.endIndex, text[index] == " " || text[index] == "\t" {
            index = text.index(after: index)
        }
    }

    mutating func consume(_ character: Character) -> Bool {
        guard index < text.endIndex, text[index] == character else { return false }
        index = text.index(after: index)
        return true
    }

    /// Lowercase letters, digits and "-".
    mutating func word() -> String {
        let start = index
        while index < text.endIndex, text[index].isASCII,
            text[index].isLetter || text[index].isNumber || text[index] == "-"
        {
            index = text.index(after: index)
        }
        return String(text[start..<index])
    }

    /// A quoted value with \" and \\ escapes, or a bare value up to a space or "|". The caller has
    /// already checked that quotes are balanced, so a quoted value always ends.
    mutating func value() -> String {
        guard consume("\"") else {
            let start = index
            while index < text.endIndex, text[index] != " ", text[index] != "|" {
                index = text.index(after: index)
            }
            return String(text[start..<index])
        }
        var value = ""
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            if character == "\"" { return value }
            if character == "\\", index < text.endIndex {
                value.append(text[index])
                index = text.index(after: index)
            } else {
                value.append(character)
            }
        }
        return value
    }
}
