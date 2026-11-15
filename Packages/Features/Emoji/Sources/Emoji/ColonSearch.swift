import Kit

/// Root search's colon search: ":smile" offers matching emoji at the top.
///
/// Budget: 100 µs per keystroke on the main thread. Anything that does not start with a colon is
/// rejected on its first byte. The index is built off the main thread at activation; until it is
/// ready, the provider answers nothing.
final class ColonSearch: InstantProvider {
    /// The most rows the provider offers.
    static let maximumRows = 6
    /// Letters after the colon before the provider answers, as in chat apps.
    static let minimumLength = 2
    /// The longest text after the colon the provider reads, in bytes. The longest name is 53, so
    /// longer text is pasted, not typed, and is refused before any work.
    static let maximumLength = 64

    let namespace = EmojiLibrary.namespace
    private let library: EmojiLibrary
    private var scratch: ColonIndex.Scratch?
    /// Usage read once per query that the user types character by character, so a keystroke that
    /// narrows the query does not read the usage service again.
    private var session: (query: String, frecency: [Int: Double])?

    init(library: EmojiLibrary) {
        self.library = library
    }

    func answer(for query: String) -> InstantAnswer? {
        guard query.utf8.first == UInt8(ascii: ":") else {
            session = nil
            return nil
        }
        var text = query.dropFirst()
        if text.utf8.last == UInt8(ascii: ":") { text = text.dropLast() }
        guard (Self.minimumLength...Self.maximumLength).contains(text.utf8.count), let first = text.utf8.first,
            Self.startsWord(first),
            let index = library.colonIndex, let catalog = library.catalog
        else {
            session = nil
            return nil
        }
        let settings = library.context.settings
        guard settings[EmojiSettings.colonSearch] else { return nil }

        let frecency = frecency(for: query, catalog: catalog)
        // Taken out while in use, so the arrays inside are not shared and nothing is copied.
        var buffers = scratch ?? ColonIndex.Scratch(count: index.count)
        scratch = nil
        let matches = index.search(
            text, limit: Self.maximumRows, includeSymbols: settings[EmojiSettings.includeSymbols],
            frecency: frecency, scratch: &buffers)
        scratch = buffers
        guard !matches.isEmpty else { return nil }
        let tone = settings[EmojiSettings.skinTone]
        let rows = matches.map { match in
            let entry = catalog.entries[match.position]
            return EmojiRows.row(
                entry, tone: tone,
                subtitle: entry.group.isEmoji ? EmojiStrings.emojiSubtitle : EmojiStrings.symbolSubtitle)
        }
        return InstantAnswer(rows: rows, claimsTop: true)
    }

    func actions(for row: Row) -> [Action] {
        library.actions(for: row)
    }

    /// Frecency by catalog position, read again when the query is not the previous one grown.
    private func frecency(for query: String, catalog: EmojiCatalog) -> [Int: Double] {
        if let session, query.hasPrefix(session.query) {
            self.session = (query, session.frecency)
            return session.frecency
        }
        var byPosition: [Int: Double] = [:]
        for (id, score) in library.context.usage.frecency(namespace: namespace) {
            if let position = catalog.position(ofKey: id.key) { byPosition[position] = score }
        }
        // Pins rank first among equal matches here too, so the grid and the colon search agree.
        for key in library.context.settings[EmojiSettings.pinned] {
            if let position = catalog.position(ofKey: key) {
                byPosition[position, default: 0] += EmojiRanking.pinWeight / EmojiRanking.usageWeight
            }
        }
        session = (query, byPosition)
        return byPosition
    }

    /// True for an ASCII letter or digit, or any non-ASCII byte, which may start a letter.
    private static func startsWord(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"), 0x80...:
            true
        default:
            false
        }
    }
}
