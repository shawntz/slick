import Kit

/// Why the harness could not do what a test asked.
public enum HarnessError: Error, Hashable, CustomStringConvertible {
    case noSuchCommand(String)
    case noSuchAction(String)
    case noSuchRow(String)
    case noSuchSettingsButton(String)
    /// The page stack is empty.
    case noPage
    /// The top page is not the kind the call needs.
    case wrongPage(expected: String)
    /// The command or action needs permissions that are not granted. The host would show its
    /// permission card instead of running it.
    case permissionRequired([Permission])
    case missingArgument(String)
    /// Submitting the form failed validation, with errors by field ID.
    case invalidForm([String: FieldError])
    /// The action opens a submenu; use ``FeatureHarness/submenu(_:)``.
    case isSubmenu(String)
    /// The action runs a handler; it has no submenu.
    case notASubmenu(String)
    /// ``FeatureHarness/waitForChange()`` was called on a page whose source has no change signal
    /// and no settings to reload on.
    case pageCannotChange
    /// No toast with a button is showing.
    case noToastAction

    public var description: String {
        switch self {
        case .noSuchCommand(let id): "no command \"\(id)\""
        case .noSuchAction(let id): "no action \"\(id)\" for the selection"
        case .noSuchRow(let id): "no visible row \"\(id)\""
        case .noSuchSettingsButton(let title): "no settings button \"\(title)\""
        case .noPage: "no page is open"
        case .wrongPage(let expected): "the top page is not a \(expected) page"
        case .permissionRequired(let permissions): "needs " + permissions.map(\.displayName).joined(separator: ", ")
        case .missingArgument(let name): "missing argument \"\(name)\""
        case .invalidForm(let errors):
            "invalid form: " + errors.sorted { $0.key < $1.key }.map { "\($0): \($1)" }.joined(separator: "; ")
        case .isSubmenu(let id): "action \"\(id)\" opens a submenu"
        case .notASubmenu(let id): "action \"\(id)\" is not a submenu"
        case .pageCannotChange: "the page's source has no change signal and reloads on no settings"
        case .noToastAction: "no toast with a button is showing"
        }
    }
}

/// A command run requested with ``ActionOutcome/run(_:arguments:)`` or by a typed keyword.
public struct CommandRun: Hashable, Sendable {
    public var id: ItemID
    public var arguments: [String: String]

    public init(id: ItemID, arguments: [String: String] = [:]) {
        self.id = id
        self.arguments = arguments
    }
}

/// An ``ActionOutcome`` without its page, so tests can compare outcomes with `==`.
public enum OutcomeKind: Hashable, Sendable {
    case close(hud: HUD?)
    case keepOpen
    case push
    case replace
    case pop
    case popToRoot
    case showRoot(query: String)
    case run(ItemID, arguments: [String: String])
    case needsPermission(Permission)
}

extension ActionOutcome {
    /// The outcome without its page, for `#expect(outcome.kind == .keepOpen)`.
    public var kind: OutcomeKind {
        switch self {
        case .close(let hud): .close(hud: hud)
        case .keepOpen: .keepOpen
        case .push: .push
        case .replace: .replace
        case .pop: .pop
        case .popToRoot: .popToRoot
        case .showRoot(let query): .showRoot(query: query)
        case .run(let id, let arguments): .run(id, arguments: arguments)
        case .needsPermission(let permission): .needsPermission(permission)
        }
    }
}
