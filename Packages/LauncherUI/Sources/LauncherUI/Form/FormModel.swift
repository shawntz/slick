import Foundation

/// A form field's value.
nonisolated public enum FormValue: Sendable, Equatable {
    /// Text, secure text, multiline text and file paths.
    case text(String)
    /// A checkbox.
    case bool(Bool)
    /// A date. Nil until the user picks one.
    case date(Date?)
    /// A dropdown's chosen option, by id.
    case option(String?)
    case tags([String])
    /// A recorded shortcut, or nil when cleared.
    case hotkey(KeyChord?)
}

/// One row of a form.
nonisolated public struct FormItem: Sendable, Equatable {
    /// What the row shows and edits.
    public enum Kind: Sendable, Equatable {
        case text(placeholder: String)
        /// Text drawn as dots. It uses AppKit's secure field editor.
        case secure(placeholder: String)
        case multiline(placeholder: String)
        case dropdown([MenuOption])
        /// A checkbox with its own label beside it.
        case checkbox(label: String)
        case date(includesTime: Bool)
        /// A path the user can type, and a button that asks the host to choose one.
        case filePath(placeholder: String, buttonTitle: String)
        /// Words the user adds with Return or a comma and removes with Delete.
        case tags(placeholder: String)
        /// Records the next shortcut pressed while focused.
        case hotkey(placeholder: String)
        /// One application, chosen from `apps` in a menu inside the panel. Each option's id is
        /// what the field stores, such as a bundle ID; its icon is the app's icon. The value is
        /// `.option(id)`, and an id that is not among `apps` shows as typed.
        case application(placeholder: String, apps: [MenuOption])
        /// Static text in the control column. Not a value.
        case description(String)
        /// A hairline between groups of fields.
        case separator
    }

    /// The key in `FormView.values`. Unique within the form.
    public var id: String
    /// The text in the right-aligned label column. Empty draws none.
    public var label: String
    public var kind: Kind
    /// The value the field starts with, or a new value the host sets.
    public var value: FormValue
    /// Drawn in red under the field. Replaces `info` while set.
    public var error: String?
    /// Help text under the field.
    public var info: String?
    /// Colours `{...}` placeholders in a text or multiline field, as snippet and quicklink
    /// editors want. Other kinds ignore it.
    public var highlightsPlaceholders = false
    /// Words a tag field offers while the user types: the first one that starts with the typed
    /// text shows as a completion that Return or Right Arrow accepts, and Down Arrow lists every
    /// match. Other kinds ignore it.
    public var suggestions: [String] = []

    public init(
        id: String, label: String, kind: Kind, value: FormValue? = nil, error: String? = nil, info: String? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.value = value ?? kind.emptyValue
        self.error = error
        self.info = info
    }

    /// Whether the row takes keyboard focus.
    var isFocusable: Bool {
        switch kind {
        case .description, .separator: false
        default: true
        }
    }

    /// The message under the field: the error, else the info.
    var message: String? { error ?? info }
}

extension FormItem.Kind {
    /// The value an untouched field of this kind has.
    nonisolated var emptyValue: FormValue {
        switch self {
        case .text, .secure, .multiline, .filePath, .description, .separator: .text("")
        case .dropdown(let options): .option(options.first?.id)
        case .checkbox: .bool(false)
        case .date: .date(nil)
        case .tags: .tags([])
        case .hotkey: .hotkey(nil)
        case .application: .option(nil)
        }
    }

    /// Whether two kinds use the same control, so one can be updated in place.
    nonisolated func usesSameControl(as other: FormItem.Kind) -> Bool {
        switch (self, other) {
        case (.text, .text), (.secure, .secure), (.multiline, .multiline), (.dropdown, .dropdown),
            (.checkbox, .checkbox), (.date, .date), (.filePath, .filePath), (.tags, .tags), (.hotkey, .hotkey),
            (.application, .application), (.description, .description), (.separator, .separator):
            true
        default: false
        }
    }
}

/// Everything a form shows.
nonisolated public struct FormContent: Sendable, Equatable {
    public var items: [FormItem]

    public init(items: [FormItem]) {
        self.items = items
    }

    public static let empty = FormContent(items: [])
}
