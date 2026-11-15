import Foundation

/// A video call service whose links Join Meeting opens.
nonisolated enum MeetingProvider: String, Codable, Hashable, Sendable, CaseIterable {
    case zoom
    case googleMeet
    case teams
    case webex
    case faceTime
    case slack
    case whereby
    case jitsi
    case goTo
    case blueJeans
    case chime
    case skype
    case ringCentral

    /// The name people know it by.
    var name: String { Strings.provider(self) }
}

/// A link that joins a call, and the service it belongs to.
nonisolated struct MeetingLink: Codable, Hashable, Sendable {
    var url: URL
    var provider: MeetingProvider
}

/// Finds the link that joins an event's call in the event's URL, location and notes.
///
/// It is a pure function, so it runs anywhere and its tests need nothing. It reads invitation text
/// as people get it: plain text, HTML from Outlook and Teams, links in angle brackets, links with no
/// scheme in a location, links wrapped by Outlook Safe Links, Google or URL Defense redirects, and
/// trailing punctuation. Dial-in numbers, help pages and settings pages are not meeting links.
nonisolated enum MeetingLinkFinder {
    /// How much of a long text is read. Invitations put the link near the top; this bounds the work
    /// for a pasted document.
    static let scanLimit = 65_536

    /// The meeting link of an event: from its URL field first, then its location, then its notes.
    static func find(url: URL?, location: String?, notes: String?) -> MeetingLink? {
        if let url, let link = classify(url) { return link }
        if let location, let link = find(in: location) { return link }
        if let notes, let link = find(in: notes) { return link }
        return nil
    }

    /// The first meeting link in a text, in reading order. It walks Unicode scalars, not characters,
    /// and looks closer only at tokens with a "/" or a ":", so ordinary words cost almost nothing.
    static func find(in text: String) -> MeetingLink? {
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        var budget = scanLimit
        var tokenStart: String.Index?
        var mayBeLink = false
        while index < scalars.endIndex, budget > 0 {
            let scalar = scalars[index]
            if isSeparator(scalar) {
                if let start = tokenStart, mayBeLink, let link = link(inToken: Substring(scalars[start..<index])) {
                    return link
                }
                tokenStart = nil
                mayBeLink = false
            } else {
                if tokenStart == nil { tokenStart = index }
                if scalar == "/" || scalar == ":" { mayBeLink = true }
            }
            budget -= UTF8.width(scalar)
            index = scalars.index(after: index)
        }
        if let start = tokenStart, mayBeLink { return link(inToken: Substring(scalars[start..<index])) }
        return nil
    }

    /// The meeting link a URL stands for, unwrapping redirects first. Nil when it is not one.
    static func classify(_ url: URL, depth: Int = 0) -> MeetingLink? {
        guard depth < 4, let scheme = url.scheme?.lowercased() else { return nil }
        let host = normalizedHost(url)
        if scheme == "http" || scheme == "https" {
            if let inner = unwrapRedirect(url, host: host) { return classify(inner, depth: depth + 1) }
            return provider(host: host, url: url).map { MeetingLink(url: url, provider: $0) }
        }
        return appProvider(scheme: scheme, host: host, url: url).map { MeetingLink(url: url, provider: $0) }
    }

    // MARK: - Tokens

    /// Characters that cannot be part of a link in invitation text: white space, the quotes and
    /// brackets that surround links in plain text and HTML, and the pipe some invitations use
    /// between links.
    private static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0...0x20, 0x7F:
            // Spaces, line breaks and other control characters.
            return true
        case 0x21..<0x7F:
            switch scalar {
            case "<", ">", "\"", "'", "`", "(", ")", "[", "]", "|": return true
            default: return false
            }
        case 0x201C, 0x201D, 0x2018, 0x2019, 0x00AB, 0x00BB:
            return true
        default:
            return scalar.properties.isWhitespace
        }
    }

    /// Schemes that open a call app directly.
    private static let appSchemes = ["zoommtg://", "zoomus://", "msteams:", "facetime://", "facetime-audio://"]

    private static func link(inToken token: Substring) -> MeetingLink? {
        guard token.utf8.count >= 8 else { return nil }
        var candidate: Substring?
        if let range = token.range(of: "https://", options: .caseInsensitive)
            ?? token.range(of: "http://", options: .caseInsensitive)
        {
            candidate = token[range.lowerBound...]
        } else if let range = appSchemes.lazy.compactMap({ token.range(of: $0, options: .caseInsensitive) }).first {
            candidate = token[range.lowerBound...]
        } else if token.contains("/"), token.contains(".") {
            // A link with no scheme, such as "meet.google.com/abc-defg-hij" in a location. It counts
            // only when its host is a meeting service's.
            let trimmed = token.drop { !$0.isLetter && !$0.isNumber }
            guard let url = makeURL("https://" + trimmed),
                provider(host: normalizedHost(url), url: url) != nil
            else { return nil }
            candidate = "https://" + trimmed
        }
        guard let candidate, let url = makeURL(String(candidate)) else { return nil }
        return classify(url)
    }

    /// Makes a URL from text found in an invitation: HTML entities decoded and trailing punctuation
    /// that ends the sentence, not the link, removed.
    private static func makeURL(_ text: String) -> URL? {
        var text = text.replacingOccurrences(of: "&amp;", with: "&")
        while let last = text.last, ".,;:!?*_{}\\".contains(last) || last == "\u{2026}" {
            text.removeLast()
        }
        guard text.count > 8 else { return nil }
        return URL(string: text)
    }

    private static func normalizedHost(_ url: URL) -> String {
        let host = (url.host(percentEncoded: false) ?? "").lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - Redirects

    /// The link inside a redirect that mail filters wrap around links, or nil.
    private static func unwrapRedirect(_ url: URL, host: String) -> URL? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        func query(_ name: String) -> URL? {
            components?.queryItems?.first { $0.name.lowercased() == name }?.value.flatMap(URL.init(string:))
        }
        if host.hasSuffix("safelinks.protection.outlook.com") { return query("url") }
        if host == "google.com", url.path == "/url" { return query("q") ?? query("url") }
        if host == "urldefense.com", url.path.hasPrefix("/v3/__") {
            // URL Defense version 3: https://urldefense.com/v3/__<link>__;<signature>
            let text = url.absoluteString
            guard let start = text.range(of: "/v3/__") else { return nil }
            let rest = text[start.upperBound...]
            let inner = rest.range(of: "__;").map { rest[..<$0.lowerBound] } ?? rest
            return URL(string: String(inner))
        }
        return nil
    }

    // MARK: - Providers

    private static func pathParts(_ url: URL) -> [String] {
        url.path(percentEncoded: false).split(separator: "/").map { String($0).lowercased() }
    }

    private static func isHost(_ host: String, _ domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    /// The service a web link joins, or nil when it is not a link that joins a call.
    private static func provider(host: String, url: URL) -> MeetingProvider? {
        let parts = pathParts(url)
        let first = parts.first ?? ""
        let hasID = parts.count >= 2 && !parts[1].isEmpty

        if isHost(host, "zoom.us") || isHost(host, "zoomgov.com") || isHost(host, "zoom.com") {
            // /j/<id> meetings, /s/<id> start links, /w/<id> webinars, /my/<name> personal rooms and
            // /wc/join/<id> the web client. /u/ finds local numbers, /meeting/register signs up.
            if ["j", "s", "w", "my"].contains(first), hasID { return .zoom }
            if first == "wc", parts.count >= 2 { return .zoom }
            return nil
        }
        if host == "meet.google.com" {
            if first == "lookup", hasID { return .googleMeet }
            return isMeetCode(first) ? .googleMeet : nil
        }
        if host == "g.co", first == "meet", hasID { return .googleMeet }
        if host == "teams.microsoft.com" || host == "teams.live.com" || isHost(host, "teams.microsoft.us")
            || host == "teams.cloud.microsoft"
        {
            if first == "l", parts.count >= 3, parts[1] == "meetup-join" { return .teams }
            if first == "meet", hasID { return .teams }
            return nil
        }
        if isHost(host, "webex.com") {
            guard !["help.webex.com", "webex.com", "status.webex.com", "web.webex.com"].contains(host) else {
                return nil
            }
            if parts.contains(where: { $0 == "j.php" || $0 == "meet" || $0 == "join" || $0 == "joinservice" }) {
                return .webex
            }
            return nil
        }
        if host == "facetime.apple.com" { return first == "join" ? .faceTime : nil }
        if isHost(host, "slack.com") { return parts.contains("huddle") && parts.count >= 2 ? .slack : nil }
        if isHost(host, "whereby.com") {
            let reserved = ["", "user", "information", "pricing", "login", "signup", "org"]
            return reserved.contains(first) ? nil : .whereby
        }
        if host == "meet.jit.si" { return first.isEmpty ? nil : .jitsi }
        if host == "global.gotomeeting.com" || host == "app.gotomeeting.com" {
            return first == "join" && hasID ? .goTo : nil
        }
        if host == "meet.goto.com" || host == "gotomeet.me" { return first.isEmpty ? nil : .goTo }
        if isHost(host, "bluejeans.com") {
            return !first.isEmpty && first.allSatisfy(\.isNumber) ? .blueJeans : nil
        }
        if host == "chime.aws" { return !first.isEmpty && first.allSatisfy(\.isNumber) ? .chime : nil }
        if host == "app.chime.aws" { return first == "meetings" && hasID ? .chime : nil }
        if host == "join.skype.com" { return first.isEmpty ? nil : .skype }
        if isHost(host, "ringcentral.com") {
            return (first == "join" || first == "j") && hasID ? .ringCentral : nil
        }
        return nil
    }

    /// A Google Meet code: three letters, four letters, three letters, joined by hyphens.
    private static func isMeetCode(_ text: String) -> Bool {
        let groups = text.split(separator: "-", omittingEmptySubsequences: false)
        return groups.map(\.count) == [3, 4, 3] && groups.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isLetter } }
    }

    /// The service a link with an app's own scheme opens.
    private static func appProvider(scheme: String, host: String, url: URL) -> MeetingProvider? {
        switch scheme {
        case "zoommtg", "zoomus":
            let query = url.query(percentEncoded: false)?.lowercased() ?? ""
            return query.contains("confno=") ? .zoom : nil
        case "msteams":
            return url.absoluteString.lowercased().contains("meetup-join") ? .teams : nil
        case "facetime", "facetime-audio":
            return .faceTime
        default:
            return nil
        }
    }
}
