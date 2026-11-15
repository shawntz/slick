import Foundation

/// Decides whether typed text is a web address, strictly, in a few microseconds.
///
/// It accepts:
///
/// - `http://` and `https://` links with a valid host, any top-level domain, and no user name
///   (`https://bank.example@evil.example` is refused).
/// - Bare domains whose top-level domain is a common one, such as `example.com` or `docs.rs`.
///   Domains whose ending is also a file extension, such as `.md`, `.py` or `.app`, need `www.`, a
///   port or a path, so `README.md` and `Safari.app` stay searches.
/// - `localhost` with a port or a path, names under `.local`, and IPv4 addresses that are private
///   or have a port or a path.
///
/// It refuses anything with white space inside, non-ASCII text, other schemes, e-mail addresses,
/// version numbers, times and plain words. Ordinary words return after one pass over their bytes:
/// with no `.`, `:` or `/` there is nothing to parse.
nonisolated enum AddressDetector {
    /// An address and the link it opens.
    struct Address: Hashable, Sendable {
        /// The link, with the scheme the text named or the one guessed: https for domains, http for
        /// local names, addresses with a port and IP addresses.
        var url: URL
        /// The host, lowercased.
        var host: String
    }

    /// Longer text is never an address someone typed.
    static let maximumLength = 2048

    static func detect(_ text: String) -> Address? {
        // Every address starts with a letter or a digit, so other features' prefixes such as "/",
        // "~", ":" and "=" are refused on their first byte.
        guard let first = text.utf8.first(where: { $0 > 0x20 }), isLetter(first) || isDigit(first) else {
            return nil
        }
        // One pass with no allocation rejects most text: words, sentences, non-ASCII.
        var hasDot = false
        var hasColon = false
        var hasSlash = false
        var seenText = false
        var pendingSpace = false
        var count = 0
        for byte in text.utf8 {
            count += 1
            if count > maximumLength || byte >= 0x80 { return nil }
            if byte <= 0x20 {
                if seenText { pendingSpace = true }
                continue
            }
            if pendingSpace { return nil }
            seenText = true
            if byte == .dot {
                hasDot = true
            } else if byte == .colon {
                hasColon = true
            } else if byte == .slash {
                hasSlash = true
            }
        }
        // Every address has a dot or a colon, except localhost with a path.
        guard hasDot || hasColon || hasSlash else { return nil }
        return parse(text.utf8.filter { $0 > 0x20 })
    }

    private static func parse(_ bytes: [UInt8]) -> Address? {
        var start = 0
        var explicitScheme: String?
        if hasPrefix(bytes, "http://") {
            explicitScheme = "http"
            start = 7
        } else if hasPrefix(bytes, "https://") {
            explicitScheme = "https"
            start = 8
        }
        let end = bytes[start...].firstIndex { $0 == .slash || $0 == .question || $0 == .hash } ?? bytes.count
        // Another scheme, such as ftp:// or file://.
        if explicitScheme == nil, end > 0, bytes[end - 1] == .colon, bytes[end...].starts(with: [.slash, .slash]) {
            return nil
        }
        let authority = bytes[start..<end]
        guard !authority.isEmpty, !authority.contains(.at), !authority.contains(.openBracket) else { return nil }

        var hostBytes = authority
        var port: Int?
        if let colon = authority.lastIndex(of: .colon) {
            guard let parsed = parsePort(authority[(colon + 1)...]) else { return nil }
            port = parsed
            hostBytes = authority[..<colon]
        }
        guard let kind = classify(hostBytes) else { return nil }
        let rest = bytes[end...]
        guard isValidRest(rest) else { return nil }
        let hasPath = !rest.isEmpty
        let hasPort = port != nil
        let host = String(decoding: hostBytes.map(lowercased), as: UTF8.self)

        let scheme: String
        switch kind {
        case .localhost:
            guard explicitScheme != nil || hasPort || hasPath else { return nil }
            scheme = explicitScheme ?? "http"
        case .local:
            scheme = explicitScheme ?? "http"
        case .ipv4(let isPrivate):
            guard explicitScheme != nil || hasPort || hasPath || isPrivate else { return nil }
            scheme = explicitScheme ?? "http"
        case .singleLabel:
            guard let explicitScheme else { return nil }
            scheme = explicitScheme
        case .domain(let tld):
            if explicitScheme == nil {
                if TopLevelDomains.ambiguous.contains(tld) {
                    guard host.hasPrefix("www.") || hasPort || hasPath else { return nil }
                } else if !TopLevelDomains.common.contains(tld) {
                    return nil
                }
            }
            scheme = explicitScheme ?? (hasPort && port != 443 ? "http" : "https")
        }
        let portText = port.map { ":\($0)" } ?? ""
        let link = scheme + "://" + host + portText + String(decoding: rest, as: UTF8.self)
        guard let url = URL(string: link) else { return nil }
        return Address(url: url, host: host)
    }

    private enum HostKind {
        case localhost
        /// A name under `.local` or `.localhost`.
        case local
        case ipv4(isPrivate: Bool)
        case singleLabel
        case domain(tld: String)
    }

    /// Valid DNS labels of ASCII letters, digits and inner hyphens, or an IPv4 address.
    private static func classify(_ host: ArraySlice<UInt8>) -> HostKind? {
        guard (1...253).contains(host.count) else { return nil }
        let labels = host.split(separator: .dot, omittingEmptySubsequences: false)
        for label in labels {
            guard (1...63).contains(label.count), label.first != .hyphen, label.last != .hyphen,
                label.allSatisfy({ isLetter($0) || isDigit($0) || $0 == .hyphen })
            else { return nil }
        }
        let last = String(decoding: labels[labels.count - 1].map(lowercased), as: UTF8.self)
        if labels.count == 1 { return last == "localhost" ? .localhost : .singleLabel }
        if labels.count == 4, let octets = ipv4Octets(labels) { return .ipv4(isPrivate: isPrivate(octets)) }
        if last == "local" || last == "localhost" { return .local }
        guard last.count >= 2, last.utf8.allSatisfy(isLetter) else { return nil }
        return .domain(tld: last)
    }

    private static func ipv4Octets(_ labels: [ArraySlice<UInt8>]) -> [Int]? {
        var octets: [Int] = []
        for label in labels {
            guard label.count <= 3, label.allSatisfy(isDigit), label.count == 1 || label.first != .zero else {
                return nil
            }
            let value = label.reduce(0) { $0 * 10 + Int($1 - .zero) }
            guard value <= 255 else { return nil }
            octets.append(value)
        }
        return octets
    }

    /// Loopback, private and link-local ranges: addresses on this Mac or its network.
    private static func isPrivate(_ octets: [Int]) -> Bool {
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): true
        case (172, let second): (16...31).contains(second)
        default: false
        }
    }

    private static func parsePort(_ digits: ArraySlice<UInt8>) -> Int? {
        guard (1...5).contains(digits.count), digits.allSatisfy(isDigit) else { return nil }
        let value = digits.reduce(0) { $0 * 10 + Int($1 - .zero) }
        return (1...65535).contains(value) ? value : nil
    }

    /// The path, query and fragment may hold only characters a URL allows, and `%` only before two
    /// hex digits.
    private static func isValidRest(_ rest: ArraySlice<UInt8>) -> Bool {
        var index = rest.startIndex
        while index < rest.endIndex {
            let byte = rest[index]
            if byte == .percent {
                guard index + 2 < rest.endIndex, isHex(rest[index + 1]), isHex(rest[index + 2]) else { return false }
                index += 3
                continue
            }
            guard allowedInRest.contains(byte) else { return false }
            index += 1
        }
        return true
    }

    /// Unreserved and reserved characters of RFC 3986, without `%`, which is checked on its own.
    private static let allowedInRest: Set<UInt8> = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/?#".utf8)

    private static func hasPrefix(_ bytes: [UInt8], _ prefix: String) -> Bool {
        let prefix = Array(prefix.utf8)
        guard bytes.count >= prefix.count else { return false }
        return zip(bytes, prefix).allSatisfy { lowercased($0) == $1 }
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        isDigit(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(lowercased(byte))
    }
}

extension UInt8 {
    fileprivate nonisolated static let dot = UInt8(ascii: ".")
    fileprivate nonisolated static let colon = UInt8(ascii: ":")
    fileprivate nonisolated static let slash = UInt8(ascii: "/")
    fileprivate nonisolated static let question = UInt8(ascii: "?")
    fileprivate nonisolated static let hash = UInt8(ascii: "#")
    fileprivate nonisolated static let at = UInt8(ascii: "@")
    fileprivate nonisolated static let openBracket = UInt8(ascii: "[")
    fileprivate nonisolated static let hyphen = UInt8(ascii: "-")
    fileprivate nonisolated static let percent = UInt8(ascii: "%")
    fileprivate nonisolated static let zero = UInt8(ascii: "0")
}
