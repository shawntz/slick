import Foundation
import Kit
import KitTemplates

/// The forms: create, edit and duplicate a quicklink, and the values for one with arguments.
final class QuicklinkForms {
    private unowned let feature: QuicklinksFeature

    init(feature: QuicklinksFeature) {
        self.feature = feature
    }

    func create(link: String = "", name: String = "") -> FormPage {
        editor(
            title: Strings.createQuicklink, draft: Quicklink(id: Quicklink.makeID(), name: name, link: link))
    }

    func edit(_ quicklink: Quicklink) -> FormPage {
        editor(title: Strings.editQuicklink, draft: quicklink)
    }

    /// A new quicklink of the user's own that starts as a copy.
    func duplicate(_ quicklink: Quicklink) -> FormPage {
        var copy = quicklink
        copy.id = Quicklink.makeID()
        copy.name = Strings.copyName(quicklink.name)
        copy.isBuiltIn = false
        copy.isEnabled = true
        return editor(title: Strings.duplicate, draft: copy)
    }

    /// Asks for a quicklink's argument values and the app, then opens it. For a quicklink chosen on
    /// a page, where the search bar holds no fields for it.
    func arguments(for entry: QuicklinkEntry) -> FormPage {
        let id = entry.id
        var fields = entry.arguments.map { argument -> FormField in
            let fieldID = Self.argumentFieldID(argument.key)
            let title = argument.name ?? Strings.argumentFallbackName
            if !argument.options.isEmpty {
                return .dropdown(
                    fieldID, title: title, options: argument.options.map { CommandArgument.Option($0) },
                    initial: argument.defaultValue ?? argument.options.first)
            }
            return .text(
                fieldID, title: title, initial: argument.defaultValue ?? "", isRequired: argument.defaultValue == nil)
        }
        fields.append(
            .application(
                "openWith", title: Strings.openWithField, initial: entry.quicklink.openWith, info: Strings.openWithInfo)
        )
        return FormPage(
            title: entry.quicklink.name, fields: fields, submitTitle: Strings.openSubmit,
            requires: entry.requires
        ) {
            [unowned feature] values, context in
            let current = try feature.current(id)
            var arguments: [String: String] = [:]
            for argument in current.arguments {
                arguments[argument.key] = values.text(Self.argumentFieldID(argument.key))
            }
            // An empty app field opens the link in the default app.
            return try await feature.open(current, context: context, values: arguments, app: values.text("openWith"))
        }
    }

    static func argumentFieldID(_ key: String) -> String {
        "argument." + key
    }

    private func editor(title: String, draft: Quicklink) -> FormPage {
        var iconOptions = [CommandArgument.Option(Strings.iconWebsite, value: "")]
        iconOptions += Strings.iconChoices.map { CommandArgument.Option($0.title, value: $0.symbol) }
        // Keep a symbol written by hand in the file, so saving the form does not drop it.
        if let icon = draft.icon, !icon.isEmpty, !iconOptions.contains(where: { $0.value == icon }) {
            iconOptions.append(CommandArgument.Option(icon, value: icon))
        }
        return FormPage(
            title: title,
            fields: [
                .text(
                    "name", title: Strings.nameField, placeholder: Strings.namePlaceholder, initial: draft.name,
                    isRequired: true),
                .text(
                    "link", title: Strings.linkField, placeholder: Strings.linkPlaceholder, initial: draft.link,
                    highlightsPlaceholders: true, isRequired: true, info: Strings.linkInfo),
                .tags("keywords", title: Strings.keywordsField, initial: draft.keywords, info: Strings.keywordsInfo),
                .application(
                    "openWith", title: Strings.openWithField, initial: draft.openWith, info: Strings.openWithInfo),
                .dropdown("icon", title: Strings.iconField, options: iconOptions, initial: draft.icon ?? ""),
                .checkbox(
                    "fallback", title: Strings.fallbackField, label: Strings.fallbackLabel, initial: draft.isFallback),
            ],
            submitTitle: Strings.saveQuicklink,
            validate: { values in
                QuicklinkFormRules.errors(in: values)
            },
            submit: { [unowned feature] values, context in
                let quicklink = try QuicklinkFormRules.quicklink(from: values, draft: draft)
                try await feature.upsert(quicklink)
                context.showToast(.success(Strings.savedQuicklink))
                return .pop
            })
    }
}

/// The checks the editor runs, and the quicklink its values describe. Import uses the same rules.
nonisolated enum QuicklinkFormRules {
    static let maximumNameLength = 100
    static let maximumKeywordLength = 32

    static func errors(in values: FormValues) -> [String: FieldError] {
        var errors: [String: FieldError] = [:]
        if values.text("name").trimmingCharacters(in: .whitespacesAndNewlines).count > maximumNameLength {
            errors["name"] = FieldError(Strings.nameTooLong)
        }
        if case .invalid(let error) = LinkTemplate.validated(values.text("link")) { errors["link"] = error }
        if let problem = keywordProblem(values.strings("keywords")) { errors["keywords"] = FieldError(problem) }
        return errors
    }

    /// The quicklink the values describe, keeping the draft's ID and state. Throws when they do not
    /// pass ``errors(in:)``, which the host has already run.
    static func quicklink(from values: FormValues, draft: Quicklink) throws -> Quicklink {
        if let error = errors(in: values).sorted(by: { $0.key < $1.key }).first?.value {
            throw ActionFailure(error.message)
        }
        let name = values.text("name").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, case .valid(let link) = LinkTemplate.validated(values.text("link")) else {
            throw ActionFailure(Strings.linkNotParsed)
        }
        var quicklink = draft
        quicklink.name = name
        quicklink.link = link
        quicklink.keywords = keywords(values.strings("keywords"))
        let app = values.text("openWith").trimmingCharacters(in: .whitespaces)
        quicklink.openWith = app.isEmpty ? nil : app
        let icon = values.text("icon")
        quicklink.icon = icon.isEmpty ? nil : icon
        quicklink.isFallback = values.bool("fallback")
        return quicklink
    }

    /// Keywords trimmed, lowercased, without blanks and repeats.
    static func keywords(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func keywordProblem(_ words: [String]) -> String? {
        for word in keywords(words) {
            if word.contains(where: { $0.isWhitespace || $0.isNewline }) { return Strings.keywordOneWord }
            if word.count > maximumKeywordLength { return Strings.keywordTooLong }
        }
        return nil
    }
}
