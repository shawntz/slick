import Foundation
import Kit

/// A deep link, read from a URL in the app's scheme. Any web page can fire such a URL, so every
/// part is checked and anything unexpected is refused rather than repaired.
///
/// | URL | Does |
/// |---|---|
/// | `<scheme>://` or `<scheme>://open` | opens the launcher |
/// | `<scheme>://search?q=<text>` | opens the launcher with the text typed |
/// | `<scheme>://commands/<feature id>/<command id>?<argument>=<value>` | runs a command, which may open its page. The panel asks first unless the user always allows that command |
/// | `<scheme>://settings` or `<scheme>://settings/<pane>` | opens settings on a pane |
/// | `<scheme>://settings/features/<feature id>` | opens one feature's settings |
nonisolated enum DeepLink: Equatable, Sendable {
    case open(query: String?)
    case command(featureID: String, commandID: String, arguments: [String: String])
    /// A settings pane by name, unchecked against the panes that exist: the router checks it.
    case settings(pane: String?)
    case featureSettings(featureID: String)

    /// The longest URL accepted, in characters.
    static let maximumLength = 2048
    /// The longest search text or argument value, in characters.
    static let maximumText = 500
    /// The longest run of spaces inside a search text or argument value. A longer run could push
    /// the rest of a value out of sight on the page that asks.
    static let maximumSpaceRun = 3
    /// The most arguments a command takes.
    static let maximumArguments = 3

    /// Reads a URL. Throws ``DeepLinkError`` for anything that is not exactly one of the forms
    /// above.
    static func parse(_ url: URL, scheme: String = Brand.urlScheme) throws(DeepLinkError) -> DeepLink {
        try parse(url.absoluteString, scheme: scheme)
    }

    static func parse(_ text: String, scheme: String = Brand.urlScheme) throws(DeepLinkError) -> DeepLink {
        guard text.count <= maximumLength else { throw .tooLong }
        guard !text.unicodeScalars.contains(where: Self.isForbidden) else { throw .forbiddenCharacter }
        guard hasValidEscapes(text), let components = URLComponents(string: text) else { throw .malformed }
        guard components.scheme?.lowercased() == scheme.lowercased() else { throw .wrongScheme }
        guard text.dropFirst(scheme.count).hasPrefix("://") else { throw .malformed }
        guard components.user == nil, components.password == nil else { throw .hasCredentials }
        guard components.port == nil else { throw .hasPort }
        guard components.fragment == nil else { throw .hasFragment }
        let route = (components.host ?? "").lowercased()
        let path = try pathSegments(components.percentEncodedPath)
        let items = try queryItems(components)

        switch route {
        case "", "open", "search":
            guard path.isEmpty else { throw .badPath }
            try allowOnly(["q"], in: items)
            let query = try items["q"].map(checkedText)
            return .open(query: query?.isEmpty == true ? nil : query)
        case "commands":
            guard path.count == 2 else { throw .badPath }
            guard isFeatureID(path[0]) else { throw .badFeatureID }
            guard isCommandID(path[1]) else { throw .badCommandID }
            guard items.count <= maximumArguments else { throw .tooManyArguments }
            var arguments: [String: String] = [:]
            for (name, value) in items {
                guard isArgumentName(name) else { throw .badItem(name) }
                arguments[name] = try checkedText(value)
            }
            return .command(featureID: path[0], commandID: path[1], arguments: arguments)
        case "settings":
            try allowOnly([], in: items)
            switch path.count {
            case 0:
                return .settings(pane: nil)
            case 1:
                guard isPaneName(path[0]) else { throw .badPath }
                return .settings(pane: path[0])
            case 2 where path[0] == "features":
                guard isFeatureID(path[1]) else { throw .badFeatureID }
                return .featureSettings(featureID: path[1])
            default:
                throw .badPath
            }
        default:
            throw .unknownRoute
        }
    }

    // MARK: Parts

    /// True when every "%" starts an escape of two hex digits. Foundation would keep a broken
    /// escape such as "%zz" as literal text; a link that has one is refused instead.
    static func hasValidEscapes(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%") {
                guard index + 2 < bytes.count, isHexDigit(bytes[index + 1]), isHexDigit(bytes[index + 2]) else {
                    return false
                }
                index += 3
            } else {
                index += 1
            }
        }
        return true
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
    }

    /// The path's segments, percent-decoded. Empty, "." and ".." segments, an encoded "/" and
    /// text that does not decode are refused.
    private static func pathSegments(_ encodedPath: String) throws(DeepLinkError) -> [String] {
        guard !encodedPath.isEmpty, encodedPath != "/" else { return [] }
        guard encodedPath.hasPrefix("/") else { throw .badPath }
        var segments: [String] = []
        for raw in encodedPath.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            guard let decoded = String(raw).removingPercentEncoding, !decoded.isEmpty, decoded != ".",
                decoded != "..", !decoded.contains("/")
            else { throw .badPath }
            segments.append(decoded)
        }
        return segments
    }

    /// The query items by name. Duplicate names, items without a value and names that are not
    /// plain words are refused.
    private static func queryItems(_ components: URLComponents) throws(DeepLinkError) -> [String: String] {
        guard let raw = components.percentEncodedQueryItems else { return [:] }
        var items: [String: String] = [:]
        for item in raw {
            guard let name = item.name.removingPercentEncoding, !name.isEmpty else { throw .malformed }
            // A "+" in a query means a space, as forms encode it.
            guard let value = item.value?.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else {
                throw .badItem(name)
            }
            guard items[name] == nil else { throw .duplicateItem(name) }
            items[name] = value
        }
        return items
    }

    private static func allowOnly(_ names: Set<String>, in items: [String: String]) throws(DeepLinkError) {
        if let extra = items.keys.sorted().first(where: { !names.contains($0) }) { throw .unexpectedItem(extra) }
    }

    /// Text a user will see or that becomes an argument: no control, format or direction-override
    /// characters, no run of more than ``maximumSpaceRun`` spaces, and not too long. Leading and
    /// trailing whitespace is dropped.
    private static func checkedText(_ text: String) throws(DeepLinkError) -> String {
        guard !text.unicodeScalars.contains(where: isForbidden) else { throw .forbiddenCharacter }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count <= maximumText else { throw .tooLong }
        guard longestSpaceRun(trimmed) <= maximumSpaceRun else { throw .tooManySpaces }
        return trimmed
    }

    /// The most space characters in a row in the text, counting every kind of space, such as the
    /// no-break space.
    static func longestSpaceRun(_ text: String) -> Int {
        var longest = 0
        var run = 0
        for scalar in text.unicodeScalars {
            if scalar.properties.generalCategory == .spaceSeparator {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        return longest
    }

    /// Control characters, invisible format characters such as the zero-width space and the tag
    /// characters, line and paragraph separators, the bidirectional controls that can make text
    /// read differently from what it is, and blanks that are not spaces: every character Unicode
    /// lets text draw as nothing, such as the Hangul filler, and the braille blank. The text and
    /// emoji presentation selectors stay, so a link can search for an emoji.
    static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format: return true
        default: break
        }
        switch scalar.value {
        case 0x2028, 0x2029, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF, 0x2800: return true
        case 0xFE0E, 0xFE0F: return false
        default: return scalar.properties.isDefaultIgnorableCodePoint
        }
    }

    /// The rule ``FeatureValidator`` applies to feature IDs: a lowercase letter, then lowercase
    /// letters, digits or "-", at most 40 characters.
    static func isFeatureID(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, ("a"..."z").contains(first), id.unicodeScalars.count <= 40 else {
            return false
        }
        return id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// Lowercase letters, digits, "-" and single "." between them, at most 80 characters.
    static func isCommandID(_ id: String) -> Bool {
        guard !id.isEmpty, id.unicodeScalars.count <= 80, !id.hasPrefix("."), !id.hasSuffix("."),
            !id.contains("..")
        else { return false }
        return id.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "."
        }
    }

    /// ASCII letters, digits, "-" and "_", at most 40 characters.
    static func isArgumentName(_ name: String) -> Bool {
        guard !name.isEmpty, name.unicodeScalars.count <= 40 else { return false }
        return name.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
                || $0 == "_"
        }
    }

    /// ASCII letters only, at most 32 characters, such as `rootSearch`.
    static func isPaneName(_ name: String) -> Bool {
        guard !name.isEmpty, name.unicodeScalars.count <= 32 else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }
    }
}

/// Why a URL was refused.
nonisolated enum DeepLinkError: Error, Equatable, Sendable {
    case tooLong
    case malformed
    case wrongScheme
    case forbiddenCharacter
    /// A search text or argument value holds more than ``DeepLink/maximumSpaceRun`` spaces in a row.
    case tooManySpaces
    case hasCredentials
    case hasPort
    case hasFragment
    case unknownRoute
    case badPath
    case badItem(String)
    case duplicateItem(String)
    case unexpectedItem(String)
    case badFeatureID
    case badCommandID
    case tooManyArguments
    // Found by the router, which knows what exists.
    case unknownCommand
    case commandOff
    /// The command declares `allowsDeepLinks: false`. Refused before the page that asks, and even
    /// when the user chose Always Allow for it.
    case commandRefusesLinks
    case unknownArgument(String)
    case unknownPane
    case unknownFeature
}
