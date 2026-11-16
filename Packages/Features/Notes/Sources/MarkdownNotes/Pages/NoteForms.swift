import Foundation
import Kit

/// The forms: Create Note, Edit Note, Rename Note and the text for Append to Note.
struct NoteForms {
    /// Field IDs.
    enum Field {
        static let title = "title"
        static let body = "body"
        static let tags = "tags"
        static let text = "text"
    }

    let feature: NotesFeature

    /// A new note. Saving shows a toast whose button opens the note.
    func create(title: String = "", body: String = "", tags: [String] = []) -> FormPage {
        let feature = feature
        return FormPage(
            title: Strings.createCommand, fields: fields(title: title, body: body, tags: tags),
            submitTitle: Strings.createSubmit,
            validate: { values in Self.check(values) },
            submit: { values, context in
                let text = await NoteWork.composed(Self.draft(from: values, original: nil))
                let name = try await feature.library.create(text)
                context.showToast(
                    Toast(
                        .success, Strings.created,
                        action: ToastAction(Strings.openNote) { _ in .push(feature.notePage(name)) }))
                return .pop
            })
    }

    /// The note as the file held it when the editor opened. Saving writes over it only while the
    /// file is still that version; otherwise the editor's text becomes a new note beside it. A note
    /// that started with a byte order mark keeps it.
    func edit(_ fileName: String, original: NoteText, version: FileVersion, byteOrderMark: Bool = false) -> FormPage {
        let feature = feature
        return FormPage(
            title: Strings.editTitle, fields: fields(title: original.title, body: original.body, tags: original.tags),
            submitTitle: Strings.saveSubmit,
            validate: { values in Self.check(values) },
            submit: { values, context in
                let draft = Self.draft(from: values, original: original)
                guard draft != original else { return .pop }
                let text = await NoteWork.composed(draft)
                switch try await feature.library.save(
                    fileName, text: text, expected: version, byteOrderMark: byteOrderMark)
                {
                case .saved:
                    context.showToast(.success(Strings.saved))
                case .savedAsCopy:
                    context.showToast(.success(Strings.savedAsCopy, message: Strings.savedAsCopyMessage))
                }
                return .pop
            })
    }

    /// A new title for the note. Only the title line changes, and the file is renamed to follow.
    func rename(_ fileName: String, title: String) -> FormPage {
        let feature = feature
        return FormPage(
            title: Strings.renameTitle,
            fields: [
                .text(
                    Field.title, title: Strings.titleField, placeholder: Strings.titlePlaceholder, initial: title,
                    isRequired: true, info: Strings.titleInfo)
            ],
            submitTitle: Strings.renameSubmit,
            validate: { values in
                NoteText.isVisible(NoteText.titleLine(values.text(Field.title))[...])
                    ? [:] : [Field.title: FieldError(Strings.needsTitle)]
            },
            submit: { values, context in
                let name = try await feature.library.rename(fileName, to: values.text(Field.title))
                let shown = feature.library.index.note(named: name)?.title ?? Strings.untitledNote
                context.showToast(.success(Strings.renamed(DisplayText.fileName(shown))))
                return .pop
            })
    }

    /// The text to add at the end of a note.
    func append(to fileName: String, title: String) -> FormPage {
        let feature = feature
        return FormPage(
            title: Strings.appendTitle(DisplayText.fileName(title)),
            fields: [
                .multiline(
                    Field.text, title: Strings.appendField, placeholder: Strings.appendPlaceholder, isRequired: true)
            ],
            submitTitle: Strings.appendSubmit,
            validate: { values in
                NoteText.isVisible(values.text(Field.text)[...])
                    ? [:] : [Field.text: FieldError(Strings.needsAppendText)]
            },
            submit: { values, _ in
                _ = try await feature.library.append(values.text(Field.text), to: fileName)
                return .close(hud: .success(Strings.appended(DisplayText.fileName(title))))
            })
    }

    private func fields(title: String, body: String, tags: [String]) -> [FormField] {
        [
            .text(
                Field.title, title: Strings.titleField, placeholder: Strings.titlePlaceholder, initial: title,
                info: Strings.titleInfo),
            .multiline(
                Field.body, title: Strings.bodyField, placeholder: Strings.bodyPlaceholder, initial: body,
                info: Strings.bodyInfo),
            .tags(
                Field.tags, title: Strings.tagsField, suggestions: feature.library.index.tags, initial: tags,
                info: Strings.tagsInfo),
        ]
    }

    /// What is wrong with the editor's values: no visible title or text, or a tag a tag line
    /// cannot hold.
    static func check(_ values: FormValues) -> [String: FieldError] {
        var errors: [String: FieldError] = [:]
        let title = NoteText.titleLine(values.text(Field.title))
        if !NoteText.isVisible(title[...]), !NoteText.isVisible(values.text(Field.body)[...]) {
            errors[Field.title] = FieldError(Strings.needsText)
        }
        let tags = values.strings(Field.tags)
        if tags.contains(where: { NoteText.cleanTag($0) == nil }) {
            errors[Field.tags] = FieldError(Strings.badTags)
        } else if tags.count > NoteText.maximumTags {
            errors[Field.tags] = FieldError(Strings.tooManyTags)
        }
        return errors
    }

    /// The note the editor's values describe. An edit keeps the original's front matter and title
    /// style; a new note's title is a heading. An empty title leaves the body's first line to be
    /// the title.
    static func draft(from values: FormValues, original: NoteText?) -> NoteText {
        let title = NoteText.titleLine(values.text(Field.title))
        var tags: [String] = []
        for tag in values.strings(Field.tags).compactMap(NoteText.cleanTag)
        where !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            tags.append(tag)
        }
        var text = original ?? NoteText(title: "", style: .heading(1), body: "")
        if title != NoteText.titleLine(text.title) { text.title = title }
        if title.isEmpty {
            text.style = .none
        } else if text.style == .none {
            text.style = .heading(1)
        }
        let body = values.text(Field.body)
        if body != text.body { text.body = body }
        text.tags = tags
        return text
    }
}
