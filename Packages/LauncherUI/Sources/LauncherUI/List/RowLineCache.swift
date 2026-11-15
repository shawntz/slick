import CoreGraphics
import CoreText

/// Typeset lines kept between draws, keyed by their text and their style, so a row that comes back,
/// or keeps its subtitle and accessories while its title highlights change, is not typeset again.
///
/// Making a Core Text line costs several microseconds and a lookup costs a hash. Typing changes
/// most titles' highlights but few subtitles, keycaps or tags, so most of a keystroke's lines are
/// found here.
///
/// Lines depend on the theme's fonts and colours, so the owner clears the cache when the theme
/// changes. It holds at most `limit` lines and starts over when full.
final class RowLineCache {
    /// What a line is, which fixes its font and colour within one theme.
    enum Role: Hashable {
        /// A title; emphasized titles dim the characters outside their highlights.
        case title(emphasized: Bool)
        case subtitle
        case accessory
        case tag(ThemeColor)
        case keycap
        /// A section title in a card or menu.
        case header
        /// The truncation mark, in the font and colour of the line it ends.
        case ellipsis(of: Ending)
    }

    /// The kinds of line that can be truncated.
    enum Ending: Hashable {
        case title, subtitle, accessory
    }

    struct Key: Hashable {
        var text: String
        var role: Role
        /// Title highlights, only while they change the look.
        var highlights: [HighlightRange] = []
        /// A colour the row asked for, before the theme's legibility rule.
        var color: CGColor?
    }

    static let limit = 512

    private var lines: [Key: CTLine] = [:]
    /// Lookups answered from the cache and lines made, since the last `removeAll()`. Tests read them.
    private(set) var hits = 0
    private(set) var misses = 0

    var count: Int { lines.count }

    /// The line for `key`, made by `make` when it is not cached.
    func line(_ key: Key, make: () -> CTLine) -> CTLine {
        if let line = lines[key] {
            hits += 1
            return line
        }
        misses += 1
        if lines.count >= Self.limit { lines.removeAll(keepingCapacity: true) }
        let line = make()
        lines[key] = line
        return line
    }

    func removeAll() {
        lines.removeAll(keepingCapacity: true)
        hits = 0
        misses = 0
    }
}
