import Foundation
import Kit
import KitStorage
import KitTemplates

/// One quicklink in an import or export file: a JSON list of these. Only the name and the link are
/// needed, so Raycast's quicklink export, a list with `name`, `link`, `openWith` and `iconName`,
/// imports too.
nonisolated struct ExchangedQuicklink: Hashable, Sendable {
    var name: String?
    var link: String?
    var keywords: [String]?
    var openWith: String?
    var icon: String?
    var enabled: Bool?
    var fallback: Bool?

    init(
        name: String? = nil, link: String? = nil, keywords: [String]? = nil, openWith: String? = nil,
        icon: String? = nil, enabled: Bool? = nil, fallback: Bool? = nil
    ) {
        self.name = name
        self.link = link
        self.keywords = keywords
        self.openWith = openWith
        self.icon = icon
        self.enabled = enabled
        self.fallback = fallback
    }
}

extension ExchangedQuicklink: Codable {
    private enum CodingKeys: String, CodingKey {
        case name, link, keywords, openWith, icon, enabled, fallback
    }

    /// Reads what it can. A field of the wrong type counts as missing, so one odd entry does not
    /// stop the rest of the file.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try? container.decodeIfPresent(String.self, forKey: .name),
            link: try? container.decodeIfPresent(String.self, forKey: .link),
            keywords: try? container.decodeIfPresent([String].self, forKey: .keywords),
            openWith: try? container.decodeIfPresent(String.self, forKey: .openWith),
            icon: try? container.decodeIfPresent(String.self, forKey: .icon),
            enabled: try? container.decodeIfPresent(Bool.self, forKey: .enabled),
            fallback: try? container.decodeIfPresent(Bool.self, forKey: .fallback))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(link, forKey: .link)
        try container.encodeIfPresent(keywords, forKey: .keywords)
        try container.encodeIfPresent(openWith, forKey: .openWith)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encodeIfPresent(enabled, forKey: .enabled)
        try container.encodeIfPresent(fallback, forKey: .fallback)
    }
}

/// What an import does, entry by entry, decided against the quicklinks the user has.
nonisolated struct QuicklinkImportPlan: Sendable {
    enum Outcome: Hashable, Sendable {
        /// Added as the file has it.
        case add
        /// Added, but turned off, because its link opens something other than a web page.
        case addTurnedOff(scheme: String)
        /// Added, but turned off, because its web link sends what the user copied or selected to
        /// the site it opens.
        case addTurnedOffSending(clipboard: Bool, selection: Bool)
        /// Skipped: a quicklink with this name and link exists, by this name.
        case duplicate(of: String)
        /// Skipped, with the reason.
        case notValid(String)
    }

    struct Item: Sendable {
        var outcome: Outcome
        /// The quicklink as it will be saved, when the outcome adds one.
        var quicklink: Quicklink?
        /// The name, or the entry's place in the file.
        var title: String
        /// The link as the file has it, after mapping.
        var link: String
        /// The app the file names to open the link, when it is a name rather than a bundle ID, so
        /// the link opens in the default app.
        var unknownApp: String?
    }

    var items: [Item] = []
    var added = 0
    /// Added turned off because the link is not for the web.
    var turnedOff = 0
    /// Added turned off because the link sends what the user copied or selected.
    var turnedOffSending = 0
    var duplicates = 0
    var invalid = 0
    var flagged = 0

    var quicklinks: [Quicklink] { items.compactMap(\.quicklink) }
}

/// Reading, planning and writing import and export files.
nonisolated enum QuicklinkExchange {
    static let maximumFileSize = 10 * 1024 * 1024
    static let maximumEntries = 10_000

    /// Reads a file the user chose in the open dialog, off the main thread: a regular file of at
    /// most ``maximumFileSize`` bytes, never read past that.
    @concurrent static func read(_ url: URL) async throws -> [ExchangedQuicklink] {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, let handle = try? FileHandle(forReadingFrom: url) else {
            throw ActionFailure(Strings.importUnreadable, message: Strings.importUnreadableMessage)
        }
        defer { try? handle.close() }
        if let size = values?.fileSize, size > maximumFileSize { throw ActionFailure(Strings.importTooLarge) }
        let data: Data
        do {
            data = try handle.read(upToCount: maximumFileSize + 1) ?? Data()
        } catch {
            throw ActionFailure(Strings.importUnreadable, message: Strings.importUnreadableMessage)
        }
        guard data.count <= maximumFileSize else { throw ActionFailure(Strings.importTooLarge) }
        return try decode(data)
    }

    /// A JSON list of quicklinks, an object with a `quicklinks` list as the feature's own file has,
    /// or a property list of Alfred's web searches.
    static func decode(_ data: Data) throws -> [ExchangedQuicklink] {
        if AlfredWebSearches.looksLikePropertyList(data) {
            guard let searches = AlfredWebSearches.decode(data) else {
                throw ActionFailure(Strings.importUnreadable, message: Strings.importUnreadableMessage)
            }
            return searches
        }
        let json = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
        guard let list = try? JSONDecoder().decode(ImportList.self, from: json) else {
            throw ActionFailure(Strings.importUnreadable, message: Strings.importUnreadableMessage)
        }
        return list.entries
    }

    /// ``plan(_:existing:makeID:)`` off the main thread: an import can hold ten thousand entries, and
    /// each link is parsed.
    @concurrent static func planInBackground(_ incoming: [ExchangedQuicklink], existing: [Quicklink]) async
        -> QuicklinkImportPlan
    {
        plan(incoming, existing: existing)
    }

    /// What each entry becomes. Nothing the user has is changed.
    ///
    /// An entry needs a name and a link the editor accepts. One with the same name and link as a
    /// quicklink already there, or earlier in the file, is a duplicate. Raycast's one unnamed
    /// `{argument}` becomes this feature's `{query}`, so the link takes typed text as the built-in
    /// searches do. A link with a scheme other than http or https is added turned off, so an
    /// imported file can never make the first Return open an app or a file. So is a web link that
    /// sends the clipboard or the selection to the site it opens. A file's
    /// fallback mark is never kept: a fallback sits under everything the user types, so the user
    /// turns it on after a look. Imported quicklinks are the user's own, with new IDs.
    static func plan(
        _ incoming: [ExchangedQuicklink], existing: [Quicklink], makeID: () -> String = Quicklink.makeID
    ) -> QuicklinkImportPlan {
        var plan = QuicklinkImportPlan()
        var seen: [String: String] = [:]
        for quicklink in existing { seen[identity(name: quicklink.name, link: quicklink.link)] = quicklink.name }
        for (position, entry) in incoming.enumerated() {
            let name = oneLine(entry.name)
            let typed = entry.link.map(mappingArgument) ?? ""
            var item = QuicklinkImportPlan.Item(
                outcome: .add, quicklink: nil, title: name ?? Strings.entryTitle(position + 1), link: typed)
            func skip(_ reason: String) {
                item.outcome = .notValid(reason)
                plan.invalid += 1
                plan.items.append(item)
            }
            guard position < maximumEntries else {
                skip(Strings.importTooMany)
                continue
            }
            guard let name else {
                skip(Strings.importNoName)
                continue
            }
            guard name.count <= QuicklinkFormRules.maximumNameLength else {
                skip(Strings.nameTooLong)
                continue
            }
            guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                skip(Strings.importNoLink)
                continue
            }
            let link: String
            switch LinkTemplate.validated(typed) {
            case .valid(let valid): link = valid
            case .invalid(let error):
                skip(error.message)
                continue
            }
            item.link = link
            let key = identity(name: name, link: link)
            if let earlier = seen[key] {
                item.outcome = .duplicate(of: earlier)
                plan.duplicates += 1
                plan.items.append(item)
                continue
            }
            seen[key] = name
            var isEnabled = entry.enabled ?? true
            let template = LinkTemplate(link)
            let reads = sendsCopiedOrSelected(template)
            if let scheme = template.scheme, scheme != "http", scheme != "https" {
                item.outcome = .addTurnedOff(scheme: scheme)
                isEnabled = false
                plan.turnedOff += 1
            } else if reads.clipboard || reads.selection {
                item.outcome = .addTurnedOffSending(clipboard: reads.clipboard, selection: reads.selection)
                isEnabled = false
                plan.turnedOffSending += 1
            }
            let openWith = bundleID(entry.openWith)
            if openWith == nil, let app = oneLine(entry.openWith) { item.unknownApp = app }
            if item.unknownApp != nil || item.outcome != .add { plan.flagged += 1 }
            let keywords = QuicklinkFormRules.keywords(entry.keywords ?? []).filter {
                QuicklinkFormRules.keywordProblem([$0]) == nil
            }
            item.quicklink = Quicklink(
                id: makeID(), name: name, link: link, keywords: keywords, openWith: openWith,
                icon: symbolName(entry.icon), isEnabled: isEnabled, isFallback: false)
            plan.added += 1
            plan.items.append(item)
        }
        return plan
    }

    /// Whether the link sends what the user copied or selected to a site the link names. A link that
    /// is only `{clipboard}` or `{selection}` opens what the user copied or selected, and sends it
    /// nowhere else.
    static func sendsCopiedOrSelected(_ link: LinkTemplate) -> (clipboard: Bool, selection: Bool) {
        var reads = (clipboard: false, selection: false)
        if link.parts.count == 1, case .value = link.parts[0] { return reads }
        for placeholder in link.template.placeholders {
            switch placeholder.kind {
            case .clipboard: reads.clipboard = true
            case .selection: reads.selection = true
            default: break
            }
        }
        return reads
    }

    /// Raycast's link with its one unnamed argument as this feature's `{query}`, which is short for
    /// `{argument name="Query"}`. A link with no unnamed argument, or more than one, or one that
    /// already takes the query, stays as it is.
    static func mappingArgument(_ link: String) -> String {
        let template = Template(link, shorthands: .query)
        let unnamed = template.placeholders.filter { placeholder in
            if case .argument(let argument) = placeholder.kind { return argument.name == nil }
            return false
        }
        let takesQuery = template.arguments.contains { $0.key == TemplateShorthands.queryArgumentName }
        guard unnamed.count == 1, !takesQuery, let placeholder = unnamed.first else { return link }
        let utf16 = link.utf16
        let start = utf16.index(utf16.startIndex, offsetBy: placeholder.sourceRange.lowerBound)
        let end = utf16.index(utf16.startIndex, offsetBy: placeholder.sourceRange.upperBound)
        let token = String(link[start..<end])
        let replacement: String
        if token.filter({ !$0.isWhitespace }) == "{argument}" {
            replacement = "{query}"
        } else if let word = token.range(of: "argument") {
            let name = " name=\"" + TemplateShorthands.queryArgumentName + "\""
            replacement = String(token[..<word.upperBound]) + name + String(token[word.upperBound...])
        } else {
            return link
        }
        return String(link[..<start]) + replacement + String(link[end...])
    }

    /// Writes every quicklink to an export file off the main thread, and returns how many.
    @concurrent static func export(_ quicklinks: [Quicklink], to url: URL) async throws -> Int {
        let items = exported(quicklinks)
        try await write(items, to: url)
        return items.count
    }

    /// Every quicklink as written to an export file. Defaults are left out to keep the file short.
    /// Links are written as Raycast reads them, with `{query}` in its long form.
    static func exported(_ quicklinks: [Quicklink]) -> [ExchangedQuicklink] {
        quicklinks.map { quicklink in
            ExchangedQuicklink(
                name: quicklink.name, link: longQuery(quicklink.link),
                keywords: quicklink.keywords.isEmpty ? nil : quicklink.keywords,
                openWith: quicklink.openWith, icon: quicklink.icon, enabled: quicklink.isEnabled ? nil : false,
                fallback: quicklink.isFallback ? true : nil)
        }
    }

    /// Writes an export file atomically, off the main thread.
    static func write(_ items: [ExchangedQuicklink], to url: URL) async throws {
        try await JSONFileStore<[ExchangedQuicklink]>(url: url).save(items)
    }

    /// The link with each `{query}` written as `{argument name="Query"}`, which means the same here
    /// and which Raycast understands too.
    static func longQuery(_ link: String) -> String {
        let template = Template(link, shorthands: .query)
        var result = link
        // From the end, so the ranges before each change stay right.
        for placeholder in template.placeholders.reversed() {
            guard case .argument(let argument) = placeholder.kind,
                argument.key == TemplateShorthands.queryArgumentName
            else { continue }
            let utf16 = result.utf16
            let start = utf16.index(utf16.startIndex, offsetBy: placeholder.sourceRange.lowerBound)
            let end = utf16.index(utf16.startIndex, offsetBy: placeholder.sourceRange.upperBound)
            let token = String(result[start..<end])
            let body = token.dropFirst().drop { $0 == " " || $0 == "\t" }
            guard body.hasPrefix("query") else { continue }
            let rest = body.dropFirst("query".count)
            let long = "{argument name=\"" + TemplateShorthands.queryArgumentName + "\"" + rest
            result = String(result[..<start]) + long + String(result[end...])
        }
        return result
    }

    /// Name and link as compared for duplicates: the name without case, and the link with `{query}`
    /// in its long form, so a link exported and imported again matches itself.
    private static func identity(name: String, link: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "\n"
            + longQuery(link.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Text on one line with runs of white space as one space, or nil when nothing is left.
    static func oneLine(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = DisplayText.oneLine(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.isEmpty ? nil : line
    }

    /// A bundle ID such as `com.example.browser`, or nil for anything else, such as an app's name.
    private static func bundleID(_ text: String?) -> String? {
        guard let text, (3...255).contains(text.utf8.count), text.contains("."),
            text.unicodeScalars.allSatisfy({
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-")
            })
        else { return nil }
        return text
    }

    /// An SF Symbol name such as `book.closed`, or nil.
    private static func symbolName(_ text: String?) -> String? {
        guard let text, (1...64).contains(text.utf8.count),
            text.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == ".") })
        else { return nil }
        return text
    }
}

/// A list of entries, or an object holding one under `quicklinks`. An entry that is not an object
/// is kept as an empty one, so it counts as not valid.
private nonisolated struct ImportList: Decodable {
    private enum CodingKeys: String, CodingKey {
        case quicklinks
    }

    /// Decodes nothing, so an entry that is not an object can be stepped over.
    private struct Skip: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    var entries: [ExchangedQuicklink] = []

    init(from decoder: any Decoder) throws {
        var list: any UnkeyedDecodingContainer
        if let top = try? decoder.unkeyedContainer() {
            list = top
        } else {
            list = try decoder.container(keyedBy: CodingKeys.self).nestedUnkeyedContainer(forKey: .quicklinks)
        }
        while !list.isAtEnd {
            if let entry = try? list.decode(ExchangedQuicklink.self) {
                entries.append(entry)
            } else {
                _ = try list.decode(Skip.self)
                entries.append(ExchangedQuicklink())
            }
        }
    }
}

/// Alfred's custom web searches, from the property list a person picks by hand.
///
/// The format is a guess from memory and has not been checked against Alfred: a dictionary with
/// `customSites`, keyed by an ID, whose values hold `keyword`, `text`, `url` with `{query}`, and
/// `enabled`. So it is read defensively: anything of another shape is skipped or counted as not
/// valid, and nothing in the file is trusted beyond the four fields.
nonisolated enum AlfredWebSearches {
    /// True for a binary property list or one written as XML.
    static func looksLikePropertyList(_ data: Data) -> Bool {
        if data.starts(with: Array("bplist".utf8)) { return true }
        let head = String(decoding: data.prefix(256), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return head.hasPrefix("<?xml") || head.hasPrefix("<!DOCTYPE plist") || head.hasPrefix("<plist")
    }

    /// The searches, ordered by name. Nil when the file is not a property list with `customSites`.
    static func decode(_ data: Data) -> [ExchangedQuicklink]? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let sites = root["customSites"] as? [String: Any]
        else { return nil }
        let searches = sites.map { id, value -> (key: String, search: ExchangedQuicklink) in
            guard let site = value as? [String: Any] else { return (id, ExchangedQuicklink()) }
            let keyword = (site["keyword"] as? String).map { [$0] }
            let enabled = site["enabled"] as? Bool
            let search = ExchangedQuicklink(
                name: name(site["text"] as? String) ?? (site["keyword"] as? String), link: site["url"] as? String,
                keywords: keyword, enabled: enabled)
            return (id, search)
        }
        return searches.sorted { ($0.search.name ?? "", $0.key) < ($1.search.name ?? "", $1.key) }.map(\.search)
    }

    /// The title Alfred shows, such as "Search Example for '{query}'", without the query, its quotes
    /// and a trailing "for": "Search Example".
    static func name(_ text: String?) -> String? {
        guard var name = text else { return nil }
        for quote in ["'", "\"", "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}", ""] {
            for closing in ["'", "\"", "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}", ""] {
                name = name.replacingOccurrences(of: quote + "{query}" + closing, with: " ")
            }
        }
        var line = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let loose = CharacterSet(charactersIn: ":-\u{2013}\u{2014} ")
        while true {
            var next = line.trimmingCharacters(in: loose)
            if next.lowercased() == "for" {
                next = ""
            } else if next.lowercased().hasSuffix(" for") {
                next = String(next.dropLast(4))
            }
            guard next != line else { break }
            line = next
        }
        return line.isEmpty ? nil : line
    }
}
