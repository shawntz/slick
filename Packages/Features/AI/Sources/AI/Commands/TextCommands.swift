import Foundation
import Kit

/// The built-in commands on text. Each runs on the text selected in the frontmost app, or on the
/// text a universal action hands it.
nonisolated enum TextCommandKind: String, CaseIterable, Hashable, Sendable {
    case improveWriting = "improve-writing"
    case fixSpellingAndGrammar = "fix-spelling-and-grammar"
    case makeShorter = "make-shorter"
    case makeLonger = "make-longer"
    case changeTone = "change-tone"
    case summarize
    case explain
    case translate

    /// The tones Change Tone offers. The value goes into the prompt; the title is what people read.
    static let tones: [CommandArgument.Option] = [
        CommandArgument.Option(Strings.TextCommands.toneProfessional, value: "professional"),
        CommandArgument.Option(Strings.TextCommands.toneFriendly, value: "friendly"),
        CommandArgument.Option(Strings.TextCommands.toneCasual, value: "casual"),
        CommandArgument.Option(Strings.TextCommands.toneConfident, value: "confident"),
    ]

    var title: String { Strings.TextCommands.title(self) }
    var keywords: [String] { Strings.TextCommands.keywords(self) }

    var icon: Icon {
        switch self {
        case .improveWriting: .symbol("wand.and.stars")
        case .fixSpellingAndGrammar: .symbol("textformat.abc.dottedunderline")
        case .makeShorter: .symbol("arrow.down.right.and.arrow.up.left")
        case .makeLonger: .symbol("arrow.up.left.and.arrow.down.right")
        case .changeTone: .symbol("theatermasks")
        case .summarize: .symbol("text.append")
        case .explain: .symbol("lightbulb")
        case .translate: .symbol("character.bubble")
        }
    }

    /// True when the result is meant to take the selection's place, so pasting it is the first action.
    var replacesSelection: Bool {
        switch self {
        case .summarize, .explain: false
        default: true
        }
    }

    /// Inline arguments: the tone for Change Tone and the language for Translate.
    var arguments: [CommandArgument] {
        switch self {
        case .changeTone:
            [
                CommandArgument(
                    "tone", placeholder: Strings.TextCommands.tonePlaceholder, kind: .dropdown(Self.tones),
                    defaultValue: Self.tones.first?.value)
            ]
        case .translate:
            [CommandArgument("language", placeholder: Strings.TextCommands.languagePlaceholder, isOptional: true)]
        default:
            []
        }
    }
}

/// Text a command works on, and whether it is selected in another app, where pasting replaces it.
nonisolated struct TextInput: Hashable, Sendable {
    var text: String
    var isSelection: Bool

    /// The most text a command sends, in UTF-8 bytes. Counting bytes is constant time.
    static let maximumBytes = 200_000

    var isTooLong: Bool { text.utf8.count > Self.maximumBytes }
    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// What a selection read gave.
enum SelectionRead {
    case text(String)
    case nothing
    case needsAccessibility
}

extension AIFeature {
    /// The eight commands on text.
    var textCommands: [Command] {
        TextCommandKind.allCases.map { kind in
            Command(
                id: kind.rawValue, title: kind.title, subtitle: Strings.TextCommands.subtitle, icon: kind.icon,
                keywords: kind.keywords, arguments: kind.arguments
            ) { [weak self] context in
                guard let self else { return .keepOpen }
                return try await self.runText(
                    kind, context: context, given: nil, tone: context.arguments["tone"],
                    language: context.arguments["language"])
            }
        }
    }

    /// The commands on text as universal actions for selected text, with Change Tone as a submenu of
    /// tones, and the user's own commands that use the selection.
    var textActionProvider: UniversalActionProvider {
        .text { [weak self] text in
            guard let self else { return [] }
            var actions = TextCommandKind.allCases.map { kind in self.universalAction(kind, text: text) }
            actions += self.preparedCommands.filter(\.usesSelection).map { prepared in
                let command = prepared.command
                return Action(command.title, id: command.id, icon: .symbol("sparkles"), section: Strings.featureName) {
                    [weak self] context in
                    guard let self else { return .keepOpen }
                    return try await self.runCustom(command, context: context, given: text)
                }
            }
            return actions
        }
    }

    private func universalAction(_ kind: TextCommandKind, text: String) -> Action {
        if kind == .changeTone {
            return .submenu(kind.title, id: kind.rawValue, icon: kind.icon, section: Strings.featureName) {
                [weak self] _ in
                TextCommandKind.tones.map { tone in
                    Action(tone.title, id: kind.rawValue + "." + tone.value) { [weak self] context in
                        guard let self else { return .keepOpen }
                        return try await self.runText(
                            kind, context: context, given: text, tone: tone.value, language: nil)
                    }
                }
            }
        }
        let title =
            kind == .translate
            ? Strings.TextCommands.translateInto(settings[AISettings.translateLanguage]) : kind.title
        return Action(title, id: kind.rawValue, icon: kind.icon, section: Strings.featureName) { [weak self] context in
            guard let self else { return .keepOpen }
            return try await self.runText(kind, context: context, given: text, tone: nil, language: nil)
        }
    }

    /// Runs a command on text: the given text, or else the selection. For a run a link stands behind,
    /// a deep link launch or ``ActionContext/startedByLink``, it shows a form instead, so nothing is
    /// read or sent until the user presses the button.
    func runText(
        _ kind: TextCommandKind, context: ActionContext, given: String?, tone: String?, language: String?
    ) async throws -> ActionOutcome {
        let toneValue = tone ?? TextCommandKind.tones.first?.value ?? ""
        let languageValue = language.flatMap { $0.isEmpty ? nil : $0 } ?? settings[AISettings.translateLanguage]
        let instruction = Prompts.instruction(for: kind, tone: toneValue, language: languageValue)
        let services = services
        if context.launch == .deeplink || context.startedByLink {
            return .push(
                .form(
                    typedTextForm(title: kind.title) { text in
                        Self.makeTextSession(
                            kind.title, instruction: instruction, input: TextInput(text: text, isSelection: false),
                            replaces: kind.replacesSelection, services: services)
                    }))
        }
        let input: TextInput
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
        if input.isBlank {
            context.showToast(
                .failure(Strings.TextCommands.noSelection, message: Strings.TextCommands.noSelectionMessage))
            return .keepOpen
        }
        guard !input.isTooLong else { throw Strings.Failures.textTooLong }
        return await open(replacing: false) {
            Self.makeTextSession(
                kind.title, instruction: instruction, input: input, replaces: kind.replacesSelection, services: services
            ).page
        }
    }

    /// The selected text in the frontmost app. Reading it needs Accessibility; without it the
    /// handler asks the host to show its card instead of reading.
    func readSelection(_ context: ActionContext) async -> SelectionRead {
        guard context.permissions.isGranted(.accessibility) else { return .needsAccessibility }
        switch await context.selection.currentSelection() {
        case .text(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: return .text(text)
        case .url(let url): return .text(url.absoluteString)
        default: return .nothing
        }
    }

    /// The answer page for a command on text.
    static func makeTextSession(
        _ title: String, instruction: String, input: TextInput, replaces: Bool, services: AnswerServices
    ) -> AnswerSession {
        let prompt = Prompts.textCommand(instruction, text: input.text)
        return promptSession(
            title, prompt: prompt, input: input, pastesFirst: replaces && input.isSelection, services: services)
    }

    /// An answer page for a prompt that came from a command, whose first question is not shown.
    static func promptSession(
        _ title: String, prompt: String, input: TextInput?, pastesFirst: Bool, services: AnswerServices
    ) -> AnswerSession {
        var conversation = services.newConversation()
        conversation.messages = [ChatMessage(role: .user, text: prompt, label: title, date: services.clock.now)]
        if let input { conversation.title = Transcript.title(from: title + ": " + input.text.prefix(200)) }
        let pasteTitle = input?.isSelection == true ? Strings.Actions.replaceSelection : Strings.Actions.pasteResult
        return AnswerSession(
            conversation: conversation, mode: .text(TextOutput(pasteTitle: pasteTitle, pastesFirst: pastesFirst)),
            title: title, services: services)
    }

    /// A form with one text field for a command a link stands behind. Nothing is read or sent until
    /// the user presses the button.
    func typedTextForm(
        title: String, field: String = Strings.Forms.text, initial: String = "",
        session: @escaping @MainActor (String) -> AnswerSession
    ) -> FormPage {
        FormPage(
            title: title,
            fields: [
                .description(Strings.Forms.deepLinkNotice),
                .multiline("text", title: field, initial: initial, isRequired: true),
            ],
            submitTitle: Strings.Forms.send,
            validate: { values in
                TextInput(text: values.text("text"), isSelection: false).isTooLong
                    ? ["text": FieldError(Strings.Failures.textTooLong.message)] : [:]
            },
            submit: { [weak self] values, _ in
                guard let self else { return .pop }
                let text = values.text("text")
                return await self.open(replacing: true) { session(text).page }
            })
    }
}
