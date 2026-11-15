import Kit

extension CommandArgument {
    /// The search bar field for a template's argument: a dropdown when it has options, optional when
    /// it has a default, named by its key so ``TemplateEnvironment/arguments`` finds the value.
    public init(_ argument: TemplateArgument) {
        let kind: Kind = argument.options.isEmpty ? .text : .dropdown(argument.options.map { Option($0) })
        self.init(
            argument.key, placeholder: argument.name ?? "Argument", kind: kind,
            isOptional: argument.defaultValue != nil, defaultValue: argument.defaultValue)
    }
}

extension Template {
    /// The template's arguments as command arguments, for a quicklink, snippet or prompt that runs as
    /// a command with fields in the search bar.
    public var commandArguments: [CommandArgument] {
        arguments.map(CommandArgument.init)
    }
}
