import Foundation
import Kit
import KitStorage
import KitTemplates

/// A command the user wrote: a name and a prompt in Kit's template language. `{selection}` stands
/// for the selected text and `{argument name="..."}` for a value typed in the search bar.
nonisolated struct CustomCommand: Codable, Hashable, Sendable, Identifiable {
    /// The command ID, `custom.<slug>-<hash>`. It never changes, so aliases and hotkeys stay.
    var id: String
    var title: String
    var prompt: String
    /// True pastes the result over the selection on Return, when the prompt uses the selection.
    var replacesSelection: Bool

    init(id: String, title: String, prompt: String, replacesSelection: Bool) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.replacesSelection = replacesSelection
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case prompt
        case replacesSelection
    }

    /// A hand-edited entry may leave out the ID or the output choice; ``CustomCommandFile/cleaned()``
    /// fills them in.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try container.decode(String.self, forKey: .title)
        prompt = try container.decode(String.self, forKey: .prompt)
        replacesSelection = try container.decodeIfPresent(Bool.self, forKey: .replacesSelection) ?? false
    }

    var template: Template { Template(prompt) }

    /// True when the prompt reads the selected text.
    var usesSelection: Bool {
        template.placeholders.contains { $0.kind == .selection }
    }

    /// A new command ID for a name.
    static func newID(for title: String) -> String {
        Command.stableID("custom", name: title, uniqueKey: UUID().uuidString)
    }
}

/// The file the user's commands live in, `commands.json` in the feature's data folder.
nonisolated struct CustomCommandFile: Codable, Hashable, Sendable {
    static let currentVersion = 1

    var version: Int
    var commands: [CustomCommand]

    init(commands: [CustomCommand] = []) {
        self.version = Self.currentVersion
        self.commands = commands
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case commands
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        commands = try container.decodeIfPresent([CustomCommand].self, forKey: .commands) ?? []
    }

    /// The commands with names on one line, empty ones dropped, and every ID valid and unique, so a
    /// hand-edited file still gives working commands.
    func cleaned() -> [CustomCommand] {
        var seen = Set<String>()
        var result: [CustomCommand] = []
        for var command in commands {
            command.title = Transcript.oneLine(command.title, limit: 80)
            guard !command.title.isEmpty, !command.prompt.isEmpty else { continue }
            if !Self.isValidID(command.id) || seen.contains(command.id) {
                command.id = Command.stableID(
                    "custom", name: command.title, uniqueKey: "\(result.count):" + command.prompt)
            }
            seen.insert(command.id)
            result.append(command)
        }
        return result
    }

    static func isValidID(_ id: String) -> Bool {
        id.hasPrefix("custom.") && id.count <= 64 && id.count > 7
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }
    }
}

/// A custom command with what its prompt asks for, parsed once off the main thread. Declarations
/// and the universal actions read these on the main thread, so they never parse a prompt there.
nonisolated struct PreparedCommand: Sendable {
    let command: CustomCommand
    /// True when the prompt reads the selected text.
    let usesSelection: Bool
    /// The search bar fields for the prompt's arguments, at most three.
    let arguments: [CommandArgument]

    init(_ command: CustomCommand) {
        let template = command.template
        self.command = command
        usesSelection = template.placeholders.contains { $0.kind == .selection }
        arguments = Array(template.commandArguments.prefix(3))
    }
}

/// Whether `commands.json` could be used.
nonisolated enum CommandFileState: Hashable, Sendable {
    /// Read, or not there yet.
    case readable
    /// There, but it could not be read. Nothing in it shows, and nothing is saved over it.
    case unreadable
    /// Written by a newer version. Its commands show, and nothing is saved over it.
    case newer
}

extension AIFeature {
    // MARK: - Loading and saving

    /// Reads `commands.json` and parses every prompt, off the main thread. A file that cannot be read
    /// is left alone: the commands it held stay unknown, settings says so, and nothing overwrites it.
    func loadCustomCommands() async {
        do {
            let file = try await commandFile.load(default: CustomCommandFile())
            preparedCommands = await Self.prepared(file)
            commandFileState = file.version > CustomCommandFile.currentVersion ? .newer : .readable
        } catch {
            preparedCommands = []
            commandFileState = .unreadable
        }
        declarationChanges?.send()
    }

    @concurrent nonisolated private static func prepared(_ file: CustomCommandFile) async -> [PreparedCommand] {
        file.cleaned().map(PreparedCommand.init)
    }

    @concurrent nonisolated private static func prepared(_ commands: [CustomCommand]) async -> [PreparedCommand] {
        commands.map(PreparedCommand.init)
    }

    /// Saves the commands after a change and tells the host to read the commands again.
    func saveCustomCommands(_ commands: [CustomCommand]) async throws {
        switch commandFileState {
        case .readable: break
        case .unreadable: throw Strings.Failures.commandsUnreadable
        case .newer: throw Strings.Failures.commandsNewer
        }
        try await commandFile.save(CustomCommandFile(commands: commands))
        preparedCommands = await Self.prepared(commands)
        declarationChanges?.send()
    }

    /// What settings shows when `commands.json` cannot be used as it is.
    var commandFileStatus: FeatureStatus? {
        switch commandFileState {
        case .readable: nil
        case .unreadable:
            FeatureStatus(.warning, Strings.Custom.unreadableTitle, message: Strings.Custom.unreadableMessage)
        case .newer: FeatureStatus(.warning, Strings.Custom.newerTitle, message: Strings.Custom.newerMessage)
        }
    }

    // MARK: - Commands

    /// One command per custom command, with Edit and Delete on its row in root search.
    var customCommandEntries: [Command] {
        preparedCommands.map { prepared in
            let command = prepared.command
            return Command(
                id: command.id, title: command.title, subtitle: Strings.Custom.subtitle, icon: .symbol("sparkles"),
                arguments: prepared.arguments
            ) { [weak self] context in
                guard let self else { return .keepOpen }
                return try await self.runCustom(command, context: context, given: nil)
            }
            .withRowActions { [weak self] in
                guard let self else { return [] }
                return [self.editCommandAction(command), self.deleteCommandAction(command)]
            }
        }
    }

    var createCommand: Command {
        Command(
            id: "create-command", title: Strings.Custom.createTitle, icon: .symbol("plus.bubble"),
            keywords: Strings.Custom.createKeywords
        ) { [weak self] _ in
            guard let self else { return .keepOpen }
            return .push(.form(self.commandForm(editing: nil)))
        }
    }

    /// Runs a custom command. The prompt is rendered with Kit's templates in the prompt style, which
    /// quotes the selection and arguments. From a deep link the rendered prompt shows in a form first,
    /// and the selection and clipboard are not read.
    func runCustom(_ command: CustomCommand, context: ActionContext, given: String?) async throws -> ActionOutcome {
        let template = command.template
        let clock = context.clock
        let services = services
        if context.launch == .deeplink {
            let environment = TemplateEnvironment(
                now: clock.now, timeZone: clock.timeZone, locale: clock.locale, arguments: context.arguments.values)
            let preview = await template.render(in: environment, style: .prompt).text
            return .push(
                .form(
                    typedTextForm(title: command.title, field: Strings.Forms.prompt, initial: preview) { text in
                        Self.promptSession(
                            command.title, prompt: text, input: nil, pastesFirst: false, services: services)
                    }))
        }
        var input: TextInput?
        if command.usesSelection {
            if let given {
                input = TextInput(text: given, isSelection: context.launch == .selection)
            } else {
                switch await readSelection(context) {
                case .needsAccessibility: return .needsPermission(.accessibility)
                case .nothing:
                    context.showToast(
                        .failure(Strings.TextCommands.noSelection, message: Strings.TextCommands.noSelectionMessage))
                    return .keepOpen
                case .text(let text): input = TextInput(text: text, isSelection: true)
                }
            }
        }
        if let input, input.isTooLong { throw Strings.Failures.textTooLong }
        let pasteboard = context.pasteboard
        let selected = input?.text
        let environment = TemplateEnvironment(
            now: clock.now, timeZone: clock.timeZone, locale: clock.locale, arguments: context.arguments.values,
            clipboard: { await pasteboard.recentText(offset: $0) }, selection: { selected })
        let prompt = await template.render(in: environment, style: .prompt).text
        guard prompt.utf8.count <= TextInput.maximumBytes * 2 else { throw Strings.Failures.textTooLong }
        return await open(replacing: false) {
            Self.promptSession(
                command.title, prompt: prompt, input: input,
                pastesFirst: command.replacesSelection && input?.isSelection == true, services: services
            ).page
        }
    }

    // MARK: - Editing

    func editCommandAction(_ command: CustomCommand) -> Action {
        Action(Strings.Custom.edit, id: "edit", icon: .symbol("pencil"), shortcut: .edit) { [weak self] _ in
            guard let self else { return .keepOpen }
            return .push(.form(self.commandForm(editing: command)))
        }
    }

    func deleteCommandAction(_ command: CustomCommand) -> Action {
        Action(
            Strings.Custom.delete, id: "delete", icon: .symbol("trash"), shortcut: .remove, style: .destructive,
            confirmation: Confirmation(
                Strings.Custom.deleteQuestion(command.title), message: Strings.Custom.deleteMessage,
                confirmTitle: Strings.Custom.deleteConfirm, isDestructive: true)
        ) { [weak self] context in
            guard let self else { return .keepOpen }
            try await self.saveCustomCommands(self.customCommands.filter { $0.id != command.id })
            context.showToast(.success(Strings.Custom.deleted))
            return .keepOpen
        }
    }

    /// The form that creates a command, or edits one and keeps its ID.
    func commandForm(editing existing: CustomCommand?) -> FormPage {
        FormPage(
            title: existing == nil ? Strings.Custom.createTitle : Strings.Custom.editTitle,
            fields: [
                .text("title", title: Strings.Custom.name, initial: existing?.title ?? "", isRequired: true),
                .multiline(
                    "prompt", title: Strings.Custom.prompt, placeholder: Strings.Custom.promptPlaceholder,
                    initial: existing?.prompt ?? "", highlightsPlaceholders: true, isRequired: true,
                    info: Strings.Custom.promptInfo),
                .checkbox(
                    "replaces", title: Strings.Custom.result, label: Strings.Custom.replacesLabel,
                    initial: existing?.replacesSelection ?? true),
            ],
            submitTitle: Strings.Custom.save,
            validate: { [weak self] values in
                self?.validateCommand(values, editing: existing) ?? [:]
            },
            submit: { [weak self] values, context in
                guard let self else { return .pop }
                let title = Transcript.oneLine(values.text("title"), limit: 80)
                let command = CustomCommand(
                    id: existing?.id ?? CustomCommand.newID(for: title), title: title, prompt: values.text("prompt"),
                    replacesSelection: values.bool("replaces"))
                var commands = self.customCommands
                if let index = commands.firstIndex(where: { $0.id == command.id }) {
                    commands[index] = command
                } else {
                    commands.append(command)
                }
                try await self.saveCustomCommands(commands)
                context.showToast(.success(Strings.Custom.saved))
                return .pop
            })
    }

    private func validateCommand(_ values: FormValues, editing existing: CustomCommand?) -> [String: FieldError] {
        var errors: [String: FieldError] = [:]
        let title = Transcript.oneLine(values.text("title"), limit: 80)
        let taken =
            customCommands.contains { $0.id != existing?.id && $0.title.lowercased() == title.lowercased() }
            || TextCommandKind.allCases.contains { $0.title.lowercased() == title.lowercased() }
        if taken { errors["title"] = FieldError(Strings.Custom.nameTaken) }
        let template = Template(values.text("prompt"))
        if let issue = template.issues.first {
            errors["prompt"] = FieldError(Strings.Custom.placeholderMistake(issue.message), range: issue.range)
        } else if template.arguments.count > 3 {
            errors["prompt"] = FieldError(Strings.Custom.tooManyArguments)
        } else if values.text("prompt").utf8.count > TextInput.maximumBytes {
            errors["prompt"] = FieldError(Strings.Failures.textTooLong.message)
        }
        return errors
    }
}
