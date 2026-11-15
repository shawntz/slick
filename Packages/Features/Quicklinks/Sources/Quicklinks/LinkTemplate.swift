import Foundation
import Kit
import KitTemplates

/// A quicklink's link: Kit's placeholder grammar, with `{query}` as a short form of
/// `{argument name="Query"}`, rendered so every value is encoded for the part of the link it lands
/// in.
///
/// Encoding rules, decided by the literal text before the value:
///
/// - In the host, the query and the fragment, everything but letters, digits and `-._~` is
///   encoded, so a value cannot add a `/`, `?`, `&`, `=` or `#`.
/// - In a path under a host, slashes stay, so a value such as `apple/swift` names a nested page.
///   The value cannot reach the query or leave the site.
/// - After a scheme with no `//`, as in `mailto:` or `tel:`, slashes are encoded too.
/// - At the very start, as in `{clipboard}` alone, the value is the link. A bare domain becomes an
///   https link. The result must then be a web link: a value can never pick another scheme.
/// - `raw` inserts a value as it is, and `percent-encode` encodes everything including slashes.
///
/// Rendering never fails. ``url(in:)`` checks the result: it must parse, keep the scheme written in
/// the template, and be a web link when the scheme came from a value.
nonisolated struct LinkTemplate: Sendable {
    /// The name of the argument that `{query}` stands for, and that built-in searches use.
    static let queryArgumentName = "Query"
    /// The short form, as Alfred and older Raycast links write it.
    static let queryShorthand = "{query}"
    static let queryExpansion = "{argument name=\"\(queryArgumentName)\"}"
    /// The longest link the form accepts, in UTF-16 code units.
    static let maximumLength = 4096

    /// One piece of a link in order: literal text, or a value and where it lands.
    enum Part: Sendable {
        case text(String)
        case value(Value)
    }

    /// One placeholder, with the template that renders it alone and the component it lands in.
    struct Value: Sendable {
        let placeholder: Placeholder
        /// The placeholder on its own, so Kit resolves and modifies its value.
        let template: Template
        let component: LinkComponent

        /// True when the user chose the encoding with `raw` or `percent-encode`.
        var isVerbatim: Bool {
            placeholder.modifiers.contains(.raw) || placeholder.modifiers.contains(.percentEncode)
        }

        /// The value with its modifiers applied and no encoding yet.
        func resolve(in environment: TemplateEnvironment) async -> String {
            var environment = environment
            // An unnamed argument is "#2" in the whole link and "#1" alone: hand its value over.
            if case .argument(let argument) = placeholder.kind, let alone = template.arguments.first {
                environment.arguments = [alone.key: environment.arguments[argument.key] ?? ""]
            }
            return await template.render(in: environment, style: .plain).text
        }
    }

    /// The link as written.
    let source: String
    /// The link with `{query}` expanded, as Kit parsed it.
    let template: Template
    let parts: [Part]
    /// The scheme written in the link, lowercased, such as `https`. Nil when the link starts with a
    /// value or has none.
    let scheme: String?
    /// The host written in an http or https link, lowercased, without user or port. Nil when a value
    /// is part of the host.
    let webHost: String?
    /// True when a value starts the link, as in `{clipboard}`.
    let startsWithValue: Bool
    /// Where `{query}` was written, in UTF-16 offsets into ``source``.
    private let shorthands: [Range<Int>]

    init(_ source: String) {
        self.source = source
        let (expanded, shorthands) = Self.expandShorthand(source)
        self.shorthands = shorthands
        template = Template(expanded)
        var scanner = ComponentScanner()
        var parts: [Part] = []
        for segment in template.segments {
            switch segment {
            case .text(let text):
                scanner.read(text)
                parts.append(.text(text))
            case .placeholder(let placeholder):
                let alone = Template(Self.substring(of: expanded, utf16: placeholder.sourceRange))
                parts.append(.value(Value(placeholder: placeholder, template: alone, component: scanner.value())))
            }
        }
        self.parts = parts
        scheme = scanner.scheme
        webHost = scanner.webHost
        startsWithValue = scanner.startsWithValue
    }

    // MARK: What the link asks for

    /// The distinct arguments, in order of first appearance. At most three.
    var arguments: [TemplateArgument] { template.arguments }

    /// The arguments as fields in the search bar.
    var commandArguments: [CommandArgument] { template.commandArguments }

    /// True when the link takes the text typed in root search: its first argument is free text and
    /// every other argument has a default.
    var takesQuery: Bool {
        guard let first = arguments.first, first.options.isEmpty else { return false }
        return arguments.dropFirst().allSatisfy { $0.defaultValue != nil }
    }

    /// True when the link has no placeholders, so it is the same every time.
    var isStatic: Bool { template.placeholders.isEmpty }

    /// Accessibility when the link reads the selected text, so the host can explain and offer to grant
    /// it instead of opening the link with the selection left out.
    var requires: [Permission] {
        let readsSelection = template.placeholders.contains { placeholder in
            if case .selection = placeholder.kind { return true }
            return false
        }
        return readsSelection ? [.accessibility] : []
    }

    /// The literal text before the first value.
    var head: String {
        var head = ""
        for part in parts {
            guard case .text(let text) = part else { break }
            head += text
        }
        return head
    }

    /// The link as a row subtitle: without `https://` and `www.`.
    var displayText: String {
        var text = Substring(source)
        for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) {
            text = text.dropFirst(prefix.count)
        }
        if text.lowercased().hasPrefix("www.") { text = text.dropFirst(4) }
        return String(text)
    }

    /// Mistakes in recognised placeholders, with ranges in ``source``.
    var issues: [TemplateIssue] {
        template.issues.map { TemplateIssue($0.message, range: originalRange($0.range)) }
    }

    // MARK: Rendering

    /// The link with every value resolved and encoded for where it lands.
    func render(in environment: TemplateEnvironment) async -> String {
        var output = ""
        for part in parts {
            switch part {
            case .text(let text):
                output += text
            case .value(let value):
                let resolved = await value.resolve(in: environment)
                output += value.isVerbatim ? resolved : LinkEncoding.encode(resolved, for: value.component)
            }
        }
        return output
    }

    /// The rendered link as a URL, checked. Throws ``LinkError``.
    func url(in environment: TemplateEnvironment) async throws -> URL {
        let text = await render(in: environment).trimmingCharacters(in: .whitespacesAndNewlines)
        return try Self.check(text, writtenScheme: scheme)
    }

    /// Checks a rendered link: it parses, keeps the scheme the template wrote, is a web link when a
    /// value supplied the scheme, and names a host when it is a web link.
    static func check(_ text: String, writtenScheme: String?) throws -> URL {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { throw LinkError.notALink }
        if let writtenScheme {
            guard scheme == writtenScheme else { throw LinkError.schemeChanged }
        } else {
            guard scheme == "http" || scheme == "https" else { throw LinkError.notWeb }
        }
        if scheme == "http" || scheme == "https", (url.host() ?? "").isEmpty { throw LinkError.notALink }
        return url
    }

    // MARK: Checking what the user typed

    /// The link to store for what the user typed, or what is wrong with it. Surrounding white space
    /// goes, and a bare address such as `example.com/search?q={query}` gets `https://`. Error
    /// ranges point into the typed text.
    static func validated(_ typed: String) -> ValidatedLink {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let leading = typed.utf16.count - typed.drop { $0.isWhitespace || $0.isNewline }.utf16.count
        let link = withScheme(trimmed)
        let added = link.utf16.count - trimmed.utf16.count
        guard let problem = LinkTemplate(link).problem() else { return .valid(link) }
        let range = problem.range.map { range in
            max(0, range.lowerBound - added + leading)..<max(0, range.upperBound - added + leading)
        }
        return .invalid(FieldError(problem.message, range: range))
    }

    /// Adds the scheme the address detector picks when the link starts with a bare address.
    static func withScheme(_ link: String) -> String {
        let template = LinkTemplate(link)
        guard !template.startsWithValue, !template.head.contains("://"),
            let address = AddressDetector.detect(template.head), let scheme = address.url.scheme
        else { return link }
        return scheme + "://" + link
    }

    /// What is wrong with the link as stored, or nil.
    func problem() -> FieldError? {
        if source.contains(where: \.isNewline) { return FieldError(Strings.linkOneLine) }
        if source.utf16.count > Self.maximumLength { return FieldError(Strings.linkTooLong) }
        if let issue = issues.first { return FieldError(Strings.placeholderMistake(issue.message), range: issue.range) }
        // A link that starts with a value can be checked only once it is rendered.
        if startsWithValue { return nil }
        guard scheme != nil else { return FieldError(Strings.linkNeedsScheme) }
        let sample = parts.map { part in
            switch part {
            case .text(let text): text
            case .value: "x"
            }
        }
        .joined()
        guard let url = URL(string: sample), url.scheme != nil else { return FieldError(Strings.linkNotParsed) }
        if scheme == "http" || scheme == "https", (url.host() ?? "").isEmpty {
            return FieldError(Strings.linkNeedsHost)
        }
        return nil
    }

    // MARK: The short form

    /// Replaces each `{query}` with the argument it stands for, and returns where each one was.
    static func expandShorthand(_ source: String) -> (String, [Range<Int>]) {
        guard source.contains(queryShorthand) else { return (source, []) }
        var result = ""
        var ranges: [Range<Int>] = []
        var rest = source[...]
        var offset = 0
        let length = queryShorthand.utf16.count
        while let found = rest.range(of: queryShorthand) {
            let before = rest[..<found.lowerBound]
            result += before
            offset += before.utf16.count
            ranges.append(offset..<offset + length)
            offset += length
            result += queryExpansion
            rest = rest[found.upperBound...]
        }
        result += rest
        return (result, ranges)
    }

    /// A range in the expanded text as a range in ``source``.
    private func originalRange(_ range: Range<Int>) -> Range<Int> {
        let lower = originalOffset(range.lowerBound, isUpper: false)
        return lower..<max(lower, originalOffset(range.upperBound, isUpper: true))
    }

    private func originalOffset(_ offset: Int, isUpper: Bool) -> Int {
        let grow = Self.queryExpansion.utf16.count - Self.queryShorthand.utf16.count
        var delta = 0
        for range in shorthands {
            let start = range.lowerBound + delta
            if offset <= start { break }
            if offset < start + Self.queryExpansion.utf16.count {
                return isUpper ? range.upperBound : range.lowerBound
            }
            delta += grow
        }
        return offset - delta
    }

    private static func substring(of text: String, utf16 range: Range<Int>) -> String {
        let utf16 = text.utf16
        let start = utf16.index(utf16.startIndex, offsetBy: range.lowerBound)
        let end = utf16.index(start, offsetBy: range.count)
        return String(text[start..<end])
    }
}

/// A typed link checked for the form: the link to store, or what is wrong with it.
nonisolated enum ValidatedLink: Hashable, Sendable {
    case valid(String)
    case invalid(FieldError)
}

/// Why a rendered link was not opened.
nonisolated enum LinkError: Error, Hashable, Sendable {
    /// The text is not a URL, or a web link has no host.
    case notALink
    /// A value supplied the scheme and it is not http or https.
    case notWeb
    /// A raw value changed the scheme the template wrote.
    case schemeChanged

    var message: String {
        switch self {
        case .notALink: Strings.linkNotValidMessage
        case .notWeb: Strings.linkNotWeb
        case .schemeChanged: Strings.linkSchemeChanged
        }
    }
}

/// Where a value sits in a link, which decides how it is encoded.
nonisolated enum LinkComponent: Hashable, Sendable {
    /// Before any scheme: the value starts the link.
    case start
    /// The host, between `//` and the next `/`, `?` or `#`.
    case host
    /// A path under a host.
    case path
    /// What follows a scheme with no `//`, as in `mailto:` or `tel:`.
    case opaque
    case query
    case fragment
}

/// How values are encoded for each component.
nonisolated enum LinkEncoding {
    /// Letters, digits and `-._~`: the characters no part of a URL gives a meaning.
    static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    static let pathCharacters = unreserved.union(CharacterSet(charactersIn: "/"))

    static func encode(_ value: String, for component: LinkComponent) -> String {
        switch component {
        case .start:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return AddressDetector.detect(trimmed)?.url.absoluteString ?? trimmed
        case .path:
            return value.addingPercentEncoding(withAllowedCharacters: pathCharacters) ?? ""
        case .host, .opaque, .query, .fragment:
            return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        }
    }
}

/// Reads a link's literal text left to right and says which component a value at the current point
/// lands in. Values never move it on: they are encoded so they cannot add a `/`, `?` or `#`.
nonisolated struct ComponentScanner {
    private enum State {
        case start, schemeColon, schemeColonSlash, host, path, opaque, query, fragment
    }

    private var state = State.start
    private var schemeText = ""
    private var hostText = ""
    private var hostHasValue = false
    private(set) var scheme: String?
    private(set) var startsWithValue = false

    /// The literal host of an http or https link, without user and port.
    var webHost: String? {
        guard scheme == "http" || scheme == "https", !hostHasValue else { return nil }
        var host = Substring(hostText)
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        if !host.hasPrefix("["), let colon = host.lastIndex(of: ":") { host = host[..<colon] }
        return host.isEmpty ? nil : host.lowercased()
    }

    mutating func read(_ text: String) {
        for scalar in text.unicodeScalars {
            read(scalar)
        }
    }

    private mutating func read(_ scalar: Unicode.Scalar) {
        switch state {
        case .start:
            if Self.isLetter(scalar) || (!schemeText.isEmpty && Self.isLaterSchemeCharacter(scalar)) {
                schemeText.unicodeScalars.append(scalar)
            } else if scalar == ":" && !schemeText.isEmpty {
                scheme = schemeText.lowercased()
                state = .schemeColon
            } else {
                // No scheme: what came first is a host, as in a bare domain.
                hostText = schemeText
                state = .host
                read(scalar)
            }
        case .schemeColon:
            if scalar == "/" {
                state = .schemeColonSlash
            } else {
                state = .opaque
                read(scalar)
            }
        case .schemeColonSlash:
            if scalar == "/" {
                state = .host
            } else {
                state = .path
                read(scalar)
            }
        case .host:
            switch scalar {
            case "/": state = .path
            case "?": state = .query
            case "#": state = .fragment
            default: hostText.unicodeScalars.append(scalar)
            }
        case .path, .opaque:
            if scalar == "?" {
                state = .query
            } else if scalar == "#" {
                state = .fragment
            }
        case .query:
            if scalar == "#" { state = .fragment }
        case .fragment:
            break
        }
    }

    /// The component a value at this point lands in.
    mutating func value() -> LinkComponent {
        switch state {
        case .start:
            guard schemeText.isEmpty else {
                hostText = schemeText
                hostHasValue = true
                state = .host
                return .host
            }
            startsWithValue = true
            state = .path
            return .start
        case .schemeColon:
            state = .opaque
            return .opaque
        case .schemeColonSlash:
            state = .path
            return .path
        case .host:
            hostHasValue = true
            return .host
        case .path: return .path
        case .opaque: return .opaque
        case .query: return .query
        case .fragment: return .fragment
        }
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    private static func isLaterSchemeCharacter(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar) || scalar == "+" || scalar == "-" || scalar == "."
    }
}
