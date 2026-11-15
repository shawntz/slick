/// One inline argument of a command, drawn as a field in the search bar after the command's title.
///
/// Declare an argument only for a value the user types. To hand data to a command from code, pass it
/// in ``ActionOutcome/run(_:arguments:)``: undeclared values reach ``ActionContext/arguments`` too.
public struct CommandArgument: Hashable, Sendable {
    /// What the field accepts.
    public enum Kind: Hashable, Sendable {
        case text
        /// Text drawn as dots, never learned or stored.
        case password
        /// A choice from fixed options.
        case dropdown([Option])
    }

    /// One choice in a dropdown argument.
    public struct Option: Hashable, Sendable {
        public var title: String
        public var value: String

        public init(_ title: String, value: String? = nil) {
            self.title = title
            self.value = value ?? title
        }
    }

    /// The key in ``CommandArguments``. Unique within the command.
    public var name: String
    /// The hint shown in the empty field.
    public var placeholder: String
    public var kind: Kind
    /// An optional argument may be left empty; the command runs with the default or nothing.
    public var isOptional: Bool
    public var defaultValue: String?

    public init(
        _ name: String,
        placeholder: String? = nil,
        kind: Kind = .text,
        isOptional: Bool = false,
        defaultValue: String? = nil
    ) {
        self.name = name
        self.placeholder = placeholder ?? name
        self.kind = kind
        self.isOptional = isOptional
        self.defaultValue = defaultValue
    }
}

/// Argument values by name, as the user entered them or another command passed them.
public struct CommandArguments: Hashable, Sendable {
    public var values: [String: String]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    /// The value for a name, or nil when it was left empty.
    public subscript(name: String) -> String? {
        guard let value = values[name], !value.isEmpty else { return nil }
        return value
    }
}
