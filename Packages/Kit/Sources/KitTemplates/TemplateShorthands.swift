/// Short forms a template may accept on top of the shared grammar. Each is off unless the feature
/// asks for it, because the same braces are common in code: `{query}` is a JavaScript
/// destructuring, and a snippet that holds one must stay as typed.
public struct TemplateShorthands: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// `{query}` for `{argument name="Query"}`, as Alfred and older Raycast links write it. It takes
    /// `default` and `options` like an argument, and shares its value with `{argument name="Query"}`.
    /// ``Template/placeholderRanges`` covers it, so a form field colors it.
    public static let query = TemplateShorthands(rawValue: 1 << 0)

    /// The argument key and name `{query}` stands for. Fill it in ``TemplateEnvironment/arguments``.
    public static let queryArgumentName = "Query"
}

extension Template {
    /// Parses a template that also accepts the given short forms. `Template(source, shorthands: [])`
    /// is the same as `Template(source)`.
    public init(_ source: String, shorthands: TemplateShorthands) {
        self.source = source
        (segments, issues) = TemplateParser(source, shorthands: shorthands).parse()
    }
}
