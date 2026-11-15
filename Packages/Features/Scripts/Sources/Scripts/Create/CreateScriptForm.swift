import Foundation
import Kit

/// The Create Script Command form: a title, a language, a mode, an optional package name and a
/// folder. Submitting writes the script from a template, shows it in Finder so the user can edit
/// it, and closes the panel.
enum CreateScriptForm {
    /// - Parameters:
    ///   - folders: The folders the script may go in: the default folder and those turned on.
    ///   - created: Runs after the file is written, to scan the folder again.
    static func page(
        folders: [ScriptFolder], library: any ScriptLibrary, created: @escaping @MainActor @Sendable () async -> Void
    ) -> FormPage {
        let languageOptions = ScriptLanguage.allCases.map { CommandArgument.Option($0.name, value: $0.rawValue) }
        let modes: [ScriptMode] = [.compact, .silent, .fullOutput, .inline, .list]
        let modeOptions = modes.map { CommandArgument.Option(Strings.modeName($0), value: $0.rawValue) }
        let folderOptions = folders.map { CommandArgument.Option($0.displayName, value: $0.path) }
        var fields: [FormField] = [
            .text("title", title: Strings.fieldTitle, placeholder: Strings.fieldTitlePlaceholder, isRequired: true),
            .dropdown("language", title: Strings.fieldLanguage, options: languageOptions),
            .dropdown("mode", title: Strings.fieldMode, options: modeOptions),
            .text("packageName", title: Strings.fieldPackage, info: Strings.fieldPackageInfo),
        ]
        if folderOptions.count > 1 {
            fields.append(.dropdown("folder", title: Strings.fieldFolder, options: folderOptions))
        }
        let defaultFolder = folders.first?.url

        // Where the script would go, or nil when the title has no letters or digits.
        let destination: @Sendable (FormValues) -> URL? = { values in
            let language = ScriptLanguage(rawValue: values.text("language")) ?? .bash
            guard let name = ScriptTemplate.fileName(for: values.text("title"), language: language) else { return nil }
            let chosen = values.text("folder")
            let folder = chosen.isEmpty ? defaultFolder : URL(filePath: chosen, directoryHint: .isDirectory)
            return folder?.appending(path: name, directoryHint: .notDirectory)
        }

        return FormPage(
            title: Strings.createTitle, fields: fields, submitTitle: Strings.createSubmit,
            validate: { values in
                guard let url = destination(values) else { return ["title": FieldError(Strings.titleNeedsLetters)] }
                if await library.exists(url) {
                    return ["title": FieldError(Strings.fileExists(url.lastPathComponent))]
                }
                return [:]
            },
            submit: { values, context in
                guard let url = destination(values) else { throw ActionFailure(Strings.titleNeedsLetters) }
                let language = ScriptLanguage(rawValue: values.text("language")) ?? .bash
                let mode = ScriptMode(rawValue: values.text("mode")) ?? .compact
                let contents = ScriptTemplate.render(
                    title: values.text("title").trimmed, language: language, mode: mode,
                    packageName: values.text("packageName").trimmed)
                try await library.create(contents, at: url)
                await created()
                await context.workspace.reveal([url])
                return .close(hud: HUD.success(Strings.created(url.lastPathComponent)))
            })
    }
}
