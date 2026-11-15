import Foundation
import Kit
import KitTemplates

/// The snippet editor, and the form that asks for a snippet's arguments before it pastes.
struct SnippetForms {
    /// What the arguments form does with the finished text.
    enum Delivery: Sendable {
        case paste
        case copy
    }

    let feature: SnippetsFeature

    /// The editor for a new snippet, or for the existing snippet `id`.
    func editor(_ draft: SnippetDraft, editing id: String? = nil) -> FormPage {
        let feature = feature
        let settings = feature.context.settings
        let prefix = SnippetsSettings.prefix(in: settings)
        return FormPage(
            title: id == nil ? Strings.createCommand : Strings.editCommand,
            fields: [
                .text(
                    FormFields.name, title: Strings.nameField, placeholder: Strings.namePlaceholder,
                    initial: draft.name, isRequired: true),
                .multiline(
                    FormFields.text, title: Strings.textField, placeholder: Strings.textPlaceholder,
                    initial: draft.text, highlightsPlaceholders: true, isRequired: true, info: Strings.textInfo),
                .text(
                    FormFields.keyword, title: Strings.keywordField, placeholder: Strings.keywordPlaceholder,
                    initial: draft.keyword, info: Strings.keywordInfo(prefix: prefix)),
                .text(
                    FormFields.collection, title: Strings.collectionField, placeholder: Strings.collectionPlaceholder,
                    initial: draft.collection,
                    info: Strings.collectionInfo(existing: feature.library.index.collections)),
                .checkbox(
                    FormFields.expands, title: Strings.expandsField, label: Strings.expandsCheckbox,
                    initial: draft.expands),
            ],
            submitTitle: id == nil ? Strings.createSubmit : Strings.saveSubmit,
            validate: { values in
                let rules = SnippetValidation.Rules(
                    prefix: SnippetsSettings.prefix(in: settings), trigger: settings[SnippetsSettings.trigger])
                return await SnippetValidation.check(
                    Self.draft(from: values), editing: id, index: feature.library.index, rules: rules)
            },
            submit: { values, context in
                let draft = Self.draft(from: values)
                if let id {
                    try await feature.library.update(id: id, with: draft)
                } else {
                    try await feature.library.add(draft)
                }
                context.showToast(.success(Strings.saved(draft.cleanName)))
                return .pop
            })
    }

    /// A form with one field per argument the snippet asks for, which then pastes or copies it.
    func arguments(for snippet: Snippet, delivery: Delivery) -> FormPage {
        let feature = feature
        let arguments = feature.library.index.arguments(of: snippet.id)
        let info = arguments.isEmpty ? Strings.pasteInfo(snippet.name) : Strings.argumentsInfo(snippet.name)
        var fields: [FormField] = [.description(info)]
        for (position, argument) in arguments.enumerated() {
            let title = argument.name ?? Strings.argumentField(position + 1)
            if argument.options.isEmpty {
                fields.append(
                    .text(
                        argument.key, title: title, placeholder: argument.defaultValue,
                        isRequired: argument.defaultValue == nil))
            } else {
                fields.append(
                    .dropdown(
                        argument.key, title: title, options: argument.options.map { CommandArgument.Option($0) },
                        initial: argument.defaultValue.flatMap { argument.options.contains($0) ? $0 : nil },
                        isRequired: true))
            }
        }
        let snippetID = snippet.id
        return FormPage(
            title: snippet.name, fields: fields,
            submitTitle: delivery == .paste ? Strings.pasteSubmit : Strings.copySubmit,
            requires: delivery == .paste ? [.accessibility] : []
        ) { values, context in
            var filled: [String: String] = [:]
            for argument in arguments { filled[argument.key] = values.text(argument.key) }
            let rendered = try await feature.render(id: snippetID, arguments: filled)
            switch delivery {
            case .paste:
                try await context.pasteboard.paste(rendered.expansion)
                return .close()
            case .copy:
                await context.pasteboard.copy(rendered.text)
                return .close(hud: HUD(Strings.copiedHUD))
            }
        }
    }

    /// A name for text saved as a snippet: its first words, made unique.
    static func suggestedName(for text: String, in index: LibraryIndex) -> String {
        var name = ""
        let line = text.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) } ?? ""
        for word in line.split(whereSeparator: \.isWhitespace) {
            let longer = name.isEmpty ? String(word) : name + " " + word
            guard longer.count <= suggestedNameLength else { break }
            name = longer
        }
        if name.isEmpty { name = String(line.prefix(suggestedNameLength)) }
        if name.isEmpty { name = Strings.untitledName }
        let taken = Set(index.snippets.map(\.name))
        return taken.contains(name) ? SnippetImport.uniqueName(name, taken: taken) : name
    }

    static let suggestedNameLength = 40

    /// The draft the editor's values describe.
    static func draft(from values: FormValues) -> SnippetDraft {
        SnippetDraft(
            name: values.text(FormFields.name), text: values.text(FormFields.text),
            keyword: values.text(FormFields.keyword), collection: values.text(FormFields.collection),
            expands: values[FormFields.expands] == nil ? true : values.bool(FormFields.expands))
    }
}
