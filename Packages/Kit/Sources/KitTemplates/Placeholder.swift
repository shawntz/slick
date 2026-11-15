/// One parsed `{...}` placeholder.
public struct Placeholder: Hashable, Sendable {
    public var kind: PlaceholderKind
    /// Modifiers in the order they apply.
    public var modifiers: [TemplateModifier]
    /// Where the placeholder sits in the source, in UTF-16 offsets, braces included.
    public var sourceRange: Range<Int>

    public init(kind: PlaceholderKind, modifiers: [TemplateModifier] = [], sourceRange: Range<Int>) {
        self.kind = kind
        self.modifiers = modifiers
        self.sourceRange = sourceRange
    }
}

/// What a placeholder stands for.
public enum PlaceholderKind: Hashable, Sendable {
    /// `{clipboard}`, `{clipboard offset=N}`: the text copied N entries ago.
    case clipboard(offset: Int)
    /// `{selection}`: the text selected in the frontmost app.
    case selection
    /// `{date}`, `{time}`, `{datetime}`, `{day}`, with optional offset, format and locale.
    case date(DateStyle, DateOptions)
    /// `{uuid}`: a new random UUID.
    case uuid
    /// `{cursor}`: where the insertion point goes after a snippet expands.
    case cursor
    /// `{argument name="..." default="..." options="a, b"}`: a value the user types.
    case argument(TemplateArgument)
    /// `{snippet name="..."}`: another snippet's text, one level deep.
    case snippet(name: String)
}

/// Which date placeholder, and so its default format.
public enum DateStyle: String, Hashable, Sendable, CaseIterable {
    /// The locale's medium date, such as "Nov 14, 2026".
    case date
    /// The locale's short time, such as "9:30 AM".
    case time
    /// Medium date and short time.
    case datetime
    /// The weekday name, such as "Saturday".
    case day
}

/// Attributes of a date placeholder.
public struct DateOptions: Hashable, Sendable {
    /// Moves the date before formatting, applied in order.
    public var offsets: [DateOffset]
    /// A Unicode TR35 pattern such as `yyyy-MM-dd`. Literal text goes in single quotes.
    public var format: String?
    /// A BCP 47 locale such as `fr-FR` for the default format. Not allowed together with `format`.
    public var locale: String?

    public init(offsets: [DateOffset] = [], format: String? = nil, locale: String? = nil) {
        self.offsets = offsets
        self.format = format
        self.locale = locale
    }
}

/// One step of a date offset, such as `+2d` or `-30m`.
public struct DateOffset: Hashable, Sendable {
    /// Units, written case-sensitively: `s`, `m` (minutes), `h`, `d`, `w`, `M` (months), `y`.
    public enum Unit: String, Hashable, Sendable, CaseIterable {
        case second = "s"
        case minute = "m"
        case hour = "h"
        case day = "d"
        case week = "w"
        case month = "M"
        case year = "y"
    }

    public var amount: Int
    public var unit: Unit

    public init(_ amount: Int, _ unit: Unit) {
        self.amount = amount
        self.unit = unit
    }
}

/// One argument a template asks the user for.
public struct TemplateArgument: Hashable, Sendable {
    /// The key its value is looked up by in ``TemplateEnvironment/arguments``: the name, or `#1`,
    /// `#2`, ... for unnamed arguments in order of appearance. Arguments with the same name share a
    /// value; each unnamed one is separate.
    public var key: String
    /// The `name` attribute, also the field's placeholder text.
    public var name: String?
    /// Used when the user leaves the field empty. An argument with a default is optional.
    public var defaultValue: String?
    /// Fixed choices, from a comma-separated `options` attribute. Non-empty makes a dropdown.
    public var options: [String]

    public init(key: String, name: String? = nil, defaultValue: String? = nil, options: [String] = []) {
        self.key = key
        self.name = name
        self.defaultValue = defaultValue
        self.options = options
    }
}

/// A transformation applied to a placeholder's value with `|`.
public enum TemplateModifier: String, Hashable, Sendable, CaseIterable {
    case uppercase
    case lowercase
    /// Removes leading and trailing white space and newlines.
    case trim
    /// Percent-encodes everything except unreserved URL characters: letters, digits, `-._~`.
    case percentEncode = "percent-encode"
    /// Makes a JSON string literal, quotes included.
    case jsonStringify = "json-stringify"
    /// Turns off the template style's default formatting for this value.
    case raw
}
