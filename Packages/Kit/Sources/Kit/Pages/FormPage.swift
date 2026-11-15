import Foundation

/// A form inside the panel, such as "Create Quicklink". Tab moves between fields and Command-Return
/// submits. The host checks ``requires``, then required fields, then ``validate``, then calls
/// ``submit``.
public struct FormPage: Sendable {
    /// Returns errors by field ID; empty when the values are fine. It may await, for example to
    /// render a template or look up stored data.
    public typealias Validator = @MainActor @Sendable (FormValues) async -> [String: FieldError]
    /// Saves the values and says what the panel does next, usually ``ActionOutcome/pop``.
    public typealias Submit = @MainActor @Sendable (FormValues, ActionContext) async throws -> ActionOutcome

    public var title: String
    public var fields: [FormField]
    /// The submit button's label, such as "Save Quicklink".
    public var submitTitle: String
    /// Permissions submitting needs, such as Accessibility for a form that pastes. The host checks
    /// them before submitting, as it does for an action.
    public var requires: [Permission]
    public var validate: Validator?
    public var submit: Submit

    public init(
        title: String,
        fields: [FormField],
        submitTitle: String = "Save",
        requires: [Permission] = [],
        validate: Validator? = nil,
        submit: @escaping Submit
    ) {
        self.title = title
        self.fields = fields
        self.submitTitle = submitTitle
        self.requires = requires
        self.validate = validate
        self.submit = submit
    }

    /// The values the form starts with, from each field's default.
    public var initialValues: FormValues {
        var values = FormValues()
        for field in fields {
            if let value = field.kind.initialValue { values[field.id] = value }
        }
        return values
    }

    /// Errors for required fields that are empty. The host shows these before calling ``validate``.
    public func missingRequiredFields(in values: FormValues) -> [String: FieldError] {
        var errors: [String: FieldError] = [:]
        for field in fields where field.isRequired && (values[field.id]?.isEmpty ?? true) {
            errors[field.id] = "Required"
        }
        return errors
    }
}

/// What is wrong with one field's value.
public struct FieldError: Hashable, Sendable, ExpressibleByStringInterpolation, CustomStringConvertible {
    public var message: String
    /// The part of a text field's value at fault, in UTF-16 offsets, such as a broken placeholder.
    /// The host selects it.
    public var range: Range<Int>?

    public init(_ message: String, range: Range<Int>? = nil) {
        self.message = message
        self.range = range
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public var description: String { message }
}

/// One field of a form. Make one with the static factories.
public struct FormField: Identifiable, Sendable {
    /// What a field is and what it starts with.
    public enum Kind: Sendable {
        /// One line. When `highlightsPlaceholders` is true, the field colors `{...}` placeholders.
        case text(placeholder: String?, initial: String, highlightsPlaceholders: Bool)
        /// Several lines. When `highlightsPlaceholders` is true, the field colors `{...}` placeholders.
        case multiline(placeholder: String?, initial: String, highlightsPlaceholders: Bool)
        case password(placeholder: String?)
        case checkbox(label: String, initial: Bool)
        case dropdown(options: [CommandArgument.Option], initial: String?)
        case date(initial: Date?, includesTime: Bool)
        /// Files chosen with an open dialog.
        case files(OpenDialogRequest)
        /// Words the user adds one at a time, offered from `suggestions` as they type.
        case tags(suggestions: [String], initial: [String])
        /// One application, chosen with an app picker and stored by bundle ID.
        case application(initial: String?)
        /// Static text, not a value.
        case description(String)
        case separator

        var initialValue: FormValue? {
            switch self {
            case .text(_, let initial, _), .multiline(_, let initial, _): .text(initial)
            case .password: .text("")
            case .checkbox(_, let initial): .bool(initial)
            case .dropdown(_, let initial): initial.map(FormValue.text)
            case .date(let initial, _): initial.map(FormValue.date)
            case .files: .files([])
            case .tags(_, let initial): .strings(initial)
            case .application(let initial): initial.map(FormValue.text)
            case .description, .separator: nil
            }
        }
    }

    /// The key in ``FormValues``. Unique within the form.
    public var id: String
    public var title: String
    public var kind: Kind
    public var isRequired: Bool
    /// Help text under the field.
    public var info: String?

    public init(id: String, title: String, kind: Kind, isRequired: Bool = false, info: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.isRequired = isRequired
        self.info = info
    }

    public static func text(
        _ id: String, title: String, placeholder: String? = nil, initial: String = "",
        highlightsPlaceholders: Bool = false, isRequired: Bool = false, info: String? = nil
    ) -> FormField {
        FormField(
            id: id, title: title,
            kind: .text(placeholder: placeholder, initial: initial, highlightsPlaceholders: highlightsPlaceholders),
            isRequired: isRequired, info: info)
    }

    public static func multiline(
        _ id: String, title: String, placeholder: String? = nil, initial: String = "",
        highlightsPlaceholders: Bool = false, isRequired: Bool = false, info: String? = nil
    ) -> FormField {
        FormField(
            id: id, title: title,
            kind: .multiline(
                placeholder: placeholder, initial: initial, highlightsPlaceholders: highlightsPlaceholders),
            isRequired: isRequired, info: info)
    }

    public static func password(_ id: String, title: String, placeholder: String? = nil, isRequired: Bool = false)
        -> FormField
    {
        FormField(id: id, title: title, kind: .password(placeholder: placeholder), isRequired: isRequired)
    }

    public static func checkbox(_ id: String, title: String, label: String, initial: Bool = false) -> FormField {
        FormField(id: id, title: title, kind: .checkbox(label: label, initial: initial))
    }

    public static func dropdown(
        _ id: String, title: String, options: [CommandArgument.Option], initial: String? = nil, isRequired: Bool = false
    ) -> FormField {
        FormField(
            id: id, title: title, kind: .dropdown(options: options, initial: initial ?? options.first?.value),
            isRequired: isRequired)
    }

    public static func date(_ id: String, title: String, initial: Date? = nil, includesTime: Bool = true) -> FormField {
        FormField(id: id, title: title, kind: .date(initial: initial, includesTime: includesTime))
    }

    public static func files(
        _ id: String, title: String, request: OpenDialogRequest = OpenDialogRequest(), isRequired: Bool = false
    ) -> FormField {
        FormField(id: id, title: title, kind: .files(request), isRequired: isRequired)
    }

    public static func tags(
        _ id: String, title: String, suggestions: [String] = [], initial: [String] = [], info: String? = nil
    ) -> FormField {
        FormField(id: id, title: title, kind: .tags(suggestions: suggestions, initial: initial), info: info)
    }

    public static func application(
        _ id: String, title: String, initial: String? = nil, isRequired: Bool = false, info: String? = nil
    ) -> FormField {
        FormField(id: id, title: title, kind: .application(initial: initial), isRequired: isRequired, info: info)
    }

    public static func description(_ text: String) -> FormField {
        FormField(id: "description-\(FNV1a.hash64(text))", title: "", kind: .description(text))
    }

    public static func separator(_ id: String = "separator") -> FormField {
        FormField(id: id, title: "", kind: .separator)
    }
}

/// One field's value.
public enum FormValue: Hashable, Sendable {
    case text(String)
    case bool(Bool)
    case date(Date)
    case files([URL])
    case strings([String])

    /// True for blank text, no files and no tags. A checkbox or a date is never empty.
    public var isEmpty: Bool {
        switch self {
        case .text(let text): text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .files(let urls): urls.isEmpty
        case .strings(let strings): strings.isEmpty
        case .bool, .date: false
        }
    }
}

/// A form's values by field ID.
public struct FormValues: Hashable, Sendable {
    public var values: [String: FormValue]

    public init(_ values: [String: FormValue] = [:]) {
        self.values = values
    }

    public subscript(id: String) -> FormValue? {
        get { values[id] }
        set { values[id] = newValue }
    }

    /// The text of a text, multiline, password, dropdown or application field; empty when missing.
    public func text(_ id: String) -> String {
        if case .text(let text) = values[id] { return text }
        return ""
    }

    /// The value of a checkbox; false when missing.
    public func bool(_ id: String) -> Bool {
        if case .bool(let value) = values[id] { return value }
        return false
    }

    /// The value of a date field.
    public func date(_ id: String) -> Date? {
        if case .date(let date) = values[id] { return date }
        return nil
    }

    /// The files of a files field; empty when missing.
    public func files(_ id: String) -> [URL] {
        if case .files(let urls) = values[id] { return urls }
        return []
    }

    /// The words of a tags field; empty when missing.
    public func strings(_ id: String) -> [String] {
        if case .strings(let strings) = values[id] { return strings }
        return []
    }
}
