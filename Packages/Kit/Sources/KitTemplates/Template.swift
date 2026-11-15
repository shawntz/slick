/// A text with dynamic placeholders, shared by snippets, quicklinks and AI prompts. The grammar is
/// compatible with Raycast's dynamic placeholders.
///
/// ## Grammar
///
/// ```
/// placeholder := "{" name attribute* ("|" modifier)* "}"
/// attribute   := key "=" value          value := "quoted, with \" and \\ escapes" | bare-word
/// name        := clipboard | selection | date | time | datetime | day | uuid | cursor | argument | snippet
/// modifier    := uppercase | lowercase | trim | percent-encode | json-stringify | raw
/// ```
///
/// White space may separate the parts. Attributes by placeholder:
///
/// | Placeholder | Attributes |
/// |---|---|
/// | `clipboard` | `offset=N`, the Nth earlier entry (0 is the current one) |
/// | `date`, `time`, `datetime`, `day` | `offset="+2y -3d +4h"` (units `s m h d w M y`), `format="yyyy-MM-dd"`, `locale="fr-FR"` |
/// | `argument` | `name`, `default`, `options="a, b, c"` |
/// | `snippet` | `name` (required) |
///
/// A brace pair that is not a known placeholder name, or that spans a line break, is plain text, so
/// code and JSON pass through unchanged. A known placeholder with a mistake (an unknown attribute or
/// modifier, a bad offset, both `format` and `locale`, a fourth distinct argument) is kept as typed
/// and reported in ``issues``, so an editor can point at it. There is no escape syntax.
///
/// ``init(_:shorthands:)`` also accepts short forms, such as `{query}` for quicklinks. They are off
/// by default, so code that uses the same braces passes through.
///
/// Rendering applies modifiers left to right, then the ``TemplateStyle``'s default formatting unless
/// `raw` is among the modifiers.
public struct Template: Hashable, Sendable {
    /// A piece of a parsed template.
    public enum Segment: Hashable, Sendable {
        case text(String)
        case placeholder(Placeholder)
    }

    /// The text as written.
    public let source: String
    public let segments: [Segment]
    /// Mistakes in placeholders that were recognised but could not be used.
    public let issues: [TemplateIssue]

    /// Parses a template. Never fails: problems end up in ``issues``.
    public init(_ source: String) {
        self.source = source
        (segments, issues) = TemplateParser(source).parse()
    }

    /// Every placeholder, in order.
    public var placeholders: [Placeholder] {
        segments.compactMap { segment in
            if case .placeholder(let placeholder) = segment { return placeholder }
            return nil
        }
    }

    /// Where each placeholder sits in ``source``, in UTF-16 offsets, for editors that color them.
    public var placeholderRanges: [Range<Int>] {
        placeholders.map(\.sourceRange)
    }

    /// The distinct arguments the template asks for, in order of first appearance. At most three.
    public var arguments: [TemplateArgument] {
        var seen = Set<String>()
        var result: [TemplateArgument] = []
        for placeholder in placeholders {
            if case .argument(let argument) = placeholder.kind, seen.insert(argument.key).inserted {
                result.append(argument)
            }
        }
        return result
    }

    /// True when rendering needs the clipboard or the selection, which a caller may want to know
    /// before reading either.
    public var readsUserContent: Bool {
        placeholders.contains { placeholder in
            switch placeholder.kind {
            case .clipboard, .selection, .snippet: true
            default: false
            }
        }
    }
}

/// A mistake in a recognised placeholder.
public struct TemplateIssue: Error, Hashable, Sendable, CustomStringConvertible {
    public var message: String
    /// The placeholder's range in the source, in UTF-16 offsets.
    public var range: Range<Int>

    public init(_ message: String, range: Range<Int>) {
        self.message = message
        self.range = range
    }

    public var description: String { "\(message) at \(range.lowerBound)" }
}
