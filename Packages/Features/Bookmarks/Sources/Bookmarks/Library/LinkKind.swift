import Foundation

/// What a bookmark's link does when opened, which decides the actions it gets.
///
/// Only web links open without a question. A file link may be an app or a script, and a link with
/// another scheme starts some other app, so both ask first. A bookmarklet or a `data:` link runs
/// code or shows content without a page, and a browser's own pages only open inside that browser,
/// so neither is offered for opening at all: the user can copy them.
nonisolated enum LinkKind: String, Codable, Hashable, Sendable {
    /// `http` and `https`.
    case web
    /// `file`, a file or folder on this Mac.
    case file
    /// Any other scheme, such as `mailto` or an app's own.
    case app
    /// `javascript`, `vbscript`, `data` and `blob`.
    case script
    /// A browser's own pages, such as `about:` and `chrome://`.
    case browserPage
    /// No scheme, or one that is not well formed.
    case invalid

    /// True for the kinds the feature offers to open: web, file and app links.
    var opens: Bool {
        switch self {
        case .web, .file, .app: true
        case .script, .browserPage, .invalid: false
        }
    }

    private static let scripts: Set<String> = ["javascript", "vbscript", "livescript", "data", "blob"]
    private static let browserPages: Set<String> = [
        "about", "chrome", "chrome-extension", "chrome-search", "chrome-untrusted", "devtools", "edge", "brave",
        "vivaldi", "opera", "moz-extension", "view-source", "place", "resource", "safari-web-extension",
        "safari-extension", "webkit-extension",
    ]

    /// The kind of a cleaned link: see ``cleaned(_:)``.
    static func of(_ link: String) -> LinkKind {
        guard let scheme = scheme(of: link) else { return .invalid }
        switch scheme {
        case "http", "https": return .web
        case "file": return .file
        case _ where scripts.contains(scheme): return .script
        case _ where browserPages.contains(scheme): return .browserPage
        default: return .app
        }
    }

    /// The scheme in lowercase, or nil when the link does not start with a well formed one.
    static func scheme(of link: String) -> String? {
        guard let colon = link.utf8.firstIndex(of: UInt8(ascii: ":")) else { return nil }
        let scheme = link.utf8[..<colon]
        guard let first = scheme.first, isLetter(first), scheme.count <= 64,
            scheme.allSatisfy({
                isLetter($0) || isDigit($0) || $0 == UInt8(ascii: "+") || $0 == UInt8(ascii: "-")
                    || $0 == UInt8(ascii: ".")
            })
        else { return nil }
        return String(decoding: scheme, as: UTF8.self).lowercased()
    }

    /// The link as a browser reads it: tabs and line breaks anywhere are dropped, and spaces and
    /// control characters at either end. Otherwise `java\nscript:` would pass for an app link.
    static func cleaned(_ link: String) -> String {
        // Most links need nothing done: check the bytes first, which costs little.
        let bytes = link.utf8
        guard let first = bytes.first, let last = bytes.last else { return link }
        if first > 0x20 && last > 0x20 && !bytes.contains(where: { $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) {
            return link
        }
        let scalars = link.unicodeScalars.filter { $0 != "\t" && $0 != "\n" && $0 != "\r" }
        var view = Substring.UnicodeScalarView(scalars)
        while let first = view.first, first.value <= 0x20 { view.removeFirst() }
        while let last = view.last, last.value <= 0x20 { view.removeLast() }
        return String(view)
    }

    /// The link as a URL Foundation can open, or nil.
    static func url(_ link: String) -> URL? {
        URL(string: link) ?? URL(string: link, encodingInvalidCharacters: true)
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
}

/// Text made from a bookmark for copying and showing.
nonisolated enum LinkText {
    /// A title for a bookmark saved without one: the host and path of a web link without `www.`, or
    /// the start of any other link.
    static func fallbackTitle(for link: String, url: URL?) -> String {
        if let url, let host = host(of: url) {
            let path = url.path(percentEncoded: false)
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            return oneLine(host + trimmed, limit: 200)
        }
        return oneLine(link, limit: 200)
    }

    /// The host of a web link without `www.`, for matching, or nil.
    static func host(of url: URL) -> String? {
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// `[title](link)` with the brackets in the title and the parentheses and spaces in the link
    /// escaped, so the result stays one Markdown link.
    static func markdown(title: String, link: String) -> String {
        var text = ""
        for character in oneLine(title.isEmpty ? link : title, limit: 1_000) {
            if character == "[" || character == "]" || character == "\\" { text.append("\\") }
            text.append(character)
        }
        var target = ""
        for character in link {
            switch character {
            case " ": target += "%20"
            case "(": target += "%28"
            case ")": target += "%29"
            case "<": target += "%3C"
            case ">": target += "%3E"
            default: target.append(character)
            }
        }
        return "[\(text)](\(target))"
    }

    /// The text on one line: line breaks, tabs and other control characters become spaces, runs of
    /// spaces shrink to one, and spaces at either end go. Longer text is cut at `limit` characters
    /// with an ellipsis. Reads no further than it needs, so a title of megabytes costs little.
    static func oneLine(_ text: String, limit: Int) -> String {
        if text.utf8.count <= limit && isOneLine(text) { return text }
        var result = ""
        var count = 0
        var pendingSpace = false
        for character in text {
            let isSpace =
                character.isWhitespace
                || character.unicodeScalars.allSatisfy { scalar in
                    let category = scalar.properties.generalCategory
                    return category == .control || category == .lineSeparator || category == .paragraphSeparator
                }
            if isSpace {
                pendingSpace = !result.isEmpty
                continue
            }
            if count + (pendingSpace ? 1 : 0) >= limit {
                result.append("\u{2026}")
                return result
            }
            if pendingSpace {
                result.append(" ")
                count += 1
                pendingSpace = false
            }
            result.append(character)
            count += 1
        }
        return result
    }

    /// True when the text has nothing ``oneLine(_:limit:)`` would change, read from its bytes: no
    /// control character, no line or paragraph separator, and no space at either end or twice in a
    /// row.
    private static func isOneLine(_ text: String) -> Bool {
        var previous: UInt8 = 0x20
        var beforePrevious: UInt8 = 0
        for byte in text.utf8 {
            if byte < 0x20 || byte == 0x7F || (byte == 0x20 && previous == 0x20) { return false }
            // C1 controls are C2 80 to C2 9F; the line and paragraph separators are E2 80 A8 and A9.
            if previous == 0xC2 && (0x80...0x9F).contains(byte) { return false }
            if beforePrevious == 0xE2 && previous == 0x80 && (byte == 0xA8 || byte == 0xA9) { return false }
            beforePrevious = previous
            previous = byte
        }
        return previous != 0x20
    }

    /// True when the text shows nothing: only spaces, control characters and invisible format
    /// characters such as a zero-width space.
    static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            scalar.properties.isWhitespace || scalar.properties.generalCategory == .format
                || scalar.properties.generalCategory == .control
        }
    }
}
