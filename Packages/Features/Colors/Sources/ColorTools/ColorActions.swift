import Foundation
import Kit

/// What a typed color's row carries.
nonisolated struct TypedPayload: Codable, Hashable, Sendable {
    var color: ColorValue
}

/// What a contrast row carries.
nonisolated struct ContrastPayload: Codable, Hashable, Sendable {
    var foreground: ColorValue
    var background: ColorValue
}

/// The actions of every row the feature makes: typed colors and contrast in root search, and the
/// history page. Built from the row's payload, and for history rows from the history as it is now.
final class ColorActions {
    /// The history command's root ID.
    static let historyCommand = ItemID.command(feature: ColorsFeature.featureID, command: "history")
    /// The pick command's root ID.
    static let pickCommand = ItemID.command(feature: ColorsFeature.featureID, command: "pick")

    private let history: ColorHistory
    private let settings: FeatureSettings

    init(history: ColorHistory, settings: FeatureSettings) {
        self.history = history
        self.settings = settings
    }

    /// The formatter for the hex case in settings.
    var formatter: ColorFormatter {
        ColorFormatter(hexCase: settings[ColorSettings.hexCase])
    }

    /// The format Return copies.
    var defaultFormat: ColorFormat {
        settings[ColorSettings.defaultFormat]
    }

    // MARK: Formats

    /// Copy in the default format first, so Return runs it, then Paste in the default format on
    /// Command-Return, then Show in Large Type on Command-L, then Copy in every other format. `after`
    /// runs once a copy or paste worked.
    func formatActions(
        for color: ColorValue, name: String?,
        after: (@MainActor @Sendable (ActionContext) async throws -> Void)? = nil
    ) -> [Action] {
        let formatter = self.formatter
        let primary = defaultFormat
        func copy(_ format: ColorFormat) -> Action {
            let text = formatter.string(color, as: format, name: name)
            let action = Action.copy(text, title: ColorStrings.copyAs(format), hud: ColorStrings.copied(text))
                .with(id: "copy-" + format.rawValue)
            return after.map(action.then) ?? action
        }
        let pasteText = formatter.string(color, as: primary, name: name)
        let paste = Action.paste(pasteText, title: ColorStrings.pasteAs(primary), shortcut: .secondaryAction)
        var actions = [copy(primary), after.map(paste.then) ?? paste, Action.showInLargeType(pasteText)]
        for format in ColorFormat.allCases where format != primary {
            actions.append(copy(format).with(section: ColorStrings.otherFormats))
        }
        return actions
    }

    // MARK: Root search

    /// A typed color: the formats, each recording the color in the history when it works, then the
    /// history.
    func forTyped(_ row: Row) -> [Action] {
        guard let payload = try? row.payload?.decode(TypedPayload.self) else { return [] }
        let history = self.history
        let color = payload.color
        let record: @MainActor @Sendable (ActionContext) async throws -> Void = { _ in
            await history.add(color, source: .typed)
        }
        return formatActions(for: color, name: nil, after: record) + [historyAction()]
    }

    /// A contrast answer: the ratio, or the ratio with its verdicts.
    func forContrast(_ row: Row) -> [Action] {
        guard let payload = try? row.payload?.decode(ContrastPayload.self) else { return [] }
        let contrast = Contrast(foreground: payload.foreground, background: payload.background)
        let result = ColorStrings.contrastResult(
            contrast.text, normal: contrast.normalText, large: contrast.largeText)
        return [
            Action.copy(contrast.text, title: ColorStrings.copyRatio, hud: ColorStrings.copied(contrast.text))
                .with(id: "copy-ratio"),
            Action.copy(result, title: ColorStrings.copyResult, hud: ColorStrings.copiedResult)
                .with(id: "copy-result"),
        ]
    }

    /// Opens the history. Hidden while the command is unavailable.
    func historyAction() -> Action {
        .runCommand(Self.historyCommand, title: ColorStrings.openHistory, icon: .symbol("swatchpalette"))
    }

    // MARK: History

    /// The actions of a history row. Copy and paste come from the row; pin, name and delete read
    /// the history again, so a stale row never changes a color it no longer shows.
    func forHistory(_ row: Row) -> [Action] {
        guard let shown = try? row.payload?.decode(ColorEntry.self) else { return [] }
        guard let entry = history.entry(shown.id) else {
            return formatActions(for: shown.color, name: shown.name)
        }
        return formatActions(for: entry.color, name: entry.name) + [
            pinAction(entry), renameAction(entry), deleteAction(entry), clearHistoryAction(),
        ]
    }

    /// The title a history row shows: the name, or the hex value.
    func title(of entry: ColorEntry) -> String {
        entry.name ?? formatter.hex(entry.color)
    }

    private func pinAction(_ entry: ColorEntry) -> Action {
        let history = self.history
        let id = entry.id
        let title = self.title(of: entry)
        let pins = !entry.isPinned
        return Action(
            pins ? ColorStrings.pin : ColorStrings.unpin, id: pins ? "pin" : "unpin",
            icon: .symbol(pins ? "pin" : "pin.slash"), shortcut: .pin
        ) { context in
            guard history.entry(id) != nil else {
                throw ActionFailure(ColorStrings.colorNotFound, message: ColorStrings.colorNotFoundMessage)
            }
            await history.setPinned(id, pins)
            context.showToast(.success(pins ? ColorStrings.pinnedToast(title) : ColorStrings.unpinnedToast(title)))
            return .keepOpen
        }
    }

    private func renameAction(_ entry: ColorEntry) -> Action {
        let history = self.history
        let id = entry.id
        return Action(ColorStrings.rename, id: "rename", icon: .symbol("character.cursor.ibeam"), shortcut: .edit) {
            _ in
            guard let current = history.entry(id) else {
                throw ActionFailure(ColorStrings.colorNotFound, message: ColorStrings.colorNotFoundMessage)
            }
            return .push(.form(Self.renameForm(current, history: history)))
        }
    }

    /// The form that names a color. Saving an empty name removes it.
    static func renameForm(_ entry: ColorEntry, history: ColorHistory) -> FormPage {
        let id = entry.id
        return FormPage(
            title: ColorStrings.rename,
            fields: [
                .text(
                    "name", title: ColorStrings.renameField, placeholder: ColorStrings.renamePlaceholder,
                    initial: entry.name ?? "", info: ColorStrings.renameInfo)
            ],
            submitTitle: ColorStrings.renameSubmit,
            validate: { values in
                let line = DisplayText.oneLine(values.text("name")).trimmingCharacters(in: .whitespaces)
                guard line.count <= ColorHistory.nameLimit else {
                    return ["name": FieldError(ColorStrings.nameTooLong(ColorHistory.nameLimit))]
                }
                return [:]
            },
            submit: { values, context in
                guard history.entry(id) != nil else {
                    throw ActionFailure(ColorStrings.colorNotFound, message: ColorStrings.colorNotFoundMessage)
                }
                let name = ColorHistory.cleanName(values.text("name"))
                await history.rename(id, to: name ?? "")
                context.showToast(.success(name == nil ? ColorStrings.removedNameToast : ColorStrings.renamedToast))
                return .pop
            })
    }

    private func deleteAction(_ entry: ColorEntry) -> Action {
        let history = self.history
        let id = entry.id
        return Action(
            ColorStrings.delete, id: "delete", icon: .symbol("trash"), shortcut: .remove, style: .destructive,
            confirmation: Confirmation(
                ColorStrings.deleteQuestion(title(of: entry)), message: ColorStrings.deleteMessage,
                confirmTitle: ColorStrings.deleteConfirm, isDestructive: true)
        ) { context in
            guard history.entry(id) != nil else {
                throw ActionFailure(ColorStrings.colorNotFound, message: ColorStrings.colorNotFoundMessage)
            }
            await history.delete(id)
            context.showToast(.success(ColorStrings.deletedToast))
            return .keepOpen
        }
    }

    /// Deletes every color that is not pinned, after asking.
    func clearHistoryAction() -> Action {
        let history = self.history
        return Action(
            ColorStrings.clearHistory, id: "clear-history", icon: .symbol("trash.slash"), shortcut: .removeAll,
            style: .destructive, confirmation: Self.clearConfirmation
        ) { context in
            await history.clear()
            context.showToast(.success(ColorStrings.clearedToast))
            return .keepOpen
        }
    }

    static let clearConfirmation = Confirmation(
        ColorStrings.clearQuestion, message: ColorStrings.clearMessage, confirmTitle: ColorStrings.clearConfirm,
        isDestructive: true)
}
