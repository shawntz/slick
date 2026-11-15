import Foundation
import Kit
import KitStorage

/// One quicklink in an import or export file: a JSON list of these. Only the name and the link are
/// needed, so Raycast's quicklink export, a list with `name`, `link` and `openWith`, imports too.
nonisolated struct ExchangedQuicklink: Codable, Hashable, Sendable {
    var name: String?
    var link: String?
    var keywords: [String]?
    var openWith: String?
    var icon: String?
    var enabled: Bool?
    var fallback: Bool?
}

/// Reading, merging and writing import and export files.
nonisolated enum QuicklinkExchange {
    static let maximumFileSize = 10 * 1024 * 1024
    static let maximumEntries = 10_000

    /// What an import added and what it skipped.
    struct Result: Sendable {
        var added: [Quicklink] = []
        var duplicates = 0
        var invalid = 0
    }

    /// Reads a file the user chose, off the main thread.
    @concurrent static func read(_ url: URL) async throws -> [ExchangedQuicklink] {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumFileSize else { throw ActionFailure(Strings.importTooLarge) }
        return try decode(try Data(contentsOf: url))
    }

    /// A list of quicklinks, or an object with a `quicklinks` list as the feature's own file has.
    static func decode(_ data: Data) throws -> [ExchangedQuicklink] {
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([ExchangedQuicklink].self, from: data) { return list }
        if let wrapped = try? decoder.decode(Wrapped.self, from: data) { return wrapped.quicklinks }
        throw ActionFailure(Strings.importUnreadable, message: Strings.importUnreadableMessage)
    }

    private struct Wrapped: Decodable {
        var quicklinks: [ExchangedQuicklink]
    }

    /// The new quicklinks among `incoming`. A quicklink with the same name and link as one already
    /// there, or earlier in the file, is a duplicate. One without a name or a usable link is not
    /// valid. Imported quicklinks are the user's own, with new IDs.
    static func merge(
        _ incoming: [ExchangedQuicklink], into existing: [Quicklink], makeID: () -> String = Quicklink.makeID
    ) -> Result {
        var result = Result()
        var seen = Set(existing.map { identity(name: $0.name, link: $0.link) })
        for (index, entry) in incoming.enumerated() {
            guard index < maximumEntries, let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                !name.isEmpty, name.count <= QuicklinkFormRules.maximumNameLength, let typed = entry.link,
                case .valid(let link) = LinkTemplate.validated(typed)
            else {
                result.invalid += 1
                continue
            }
            guard seen.insert(identity(name: name, link: link)).inserted else {
                result.duplicates += 1
                continue
            }
            let keywords = QuicklinkFormRules.keywords(entry.keywords ?? []).filter {
                QuicklinkFormRules.keywordProblem([$0]) == nil
            }
            result.added.append(
                Quicklink(
                    id: makeID(), name: name, link: link, keywords: keywords, openWith: bundleID(entry.openWith),
                    icon: symbolName(entry.icon), isEnabled: entry.enabled ?? true, isFallback: entry.fallback ?? false)
            )
        }
        return result
    }

    /// ``merge(_:into:makeID:)`` off the main thread: an import can hold ten thousand entries, and
    /// each link is parsed.
    @concurrent static func mergeInBackground(_ incoming: [ExchangedQuicklink], into existing: [Quicklink]) async
        -> Result
    {
        merge(incoming, into: existing)
    }

    /// Writes every quicklink to an export file off the main thread, and returns how many.
    @concurrent static func export(_ quicklinks: [Quicklink], to url: URL) async throws -> Int {
        let items = exported(quicklinks)
        try await write(items, to: url)
        return items.count
    }

    /// Every quicklink as written to an export file. Defaults are left out to keep the file short.
    static func exported(_ quicklinks: [Quicklink]) -> [ExchangedQuicklink] {
        quicklinks.map { quicklink in
            ExchangedQuicklink(
                name: quicklink.name, link: quicklink.link,
                keywords: quicklink.keywords.isEmpty ? nil : quicklink.keywords,
                openWith: quicklink.openWith, icon: quicklink.icon, enabled: quicklink.isEnabled ? nil : false,
                fallback: quicklink.isFallback ? true : nil)
        }
    }

    /// Writes an export file atomically, off the main thread.
    static func write(_ items: [ExchangedQuicklink], to url: URL) async throws {
        try await JSONFileStore<[ExchangedQuicklink]>(url: url).save(items)
    }

    private static func identity(name: String, link: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "\n"
            + link.trimmingCharacters(in: .whitespacesAndNewlines)
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
