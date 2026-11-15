extension Action {
    /// A copy of the action that runs `after` once the handler has returned without throwing, keeping
    /// the handler's outcome. For a submenu, every entry its loader makes gets the same step. Use it
    /// to record history after a standard `.copy` or `.paste` without rebuilding the action.
    public func then(_ after: @escaping @MainActor @Sendable (ActionContext) async throws -> Void) -> Action {
        var copy = self
        switch kind {
        case .run(let handler):
            copy.kind = .run { context in
                let outcome = try await handler(context)
                try await after(context)
                return outcome
            }
        case .submenu(let load):
            copy.kind = .submenu { context in
                await load(context).map { $0.then(after) }
            }
        }
        return copy
    }

    /// A copy of the action that records a use of its row in ``UsageService`` when it runs from one
    /// of the feature's pages, which fills recents such as "Recently Used Emoji". Root records uses
    /// of root search rows itself, so a run from root is not counted twice.
    public func recordingUse() -> Action {
        then { context in
            guard context.launch == .page, let row = context.row else { return }
            context.usage.recordUse(of: row)
        }
    }
}

extension Array where Element == Action {
    /// The action Return runs: the first.
    public var primary: Action? { first }

    /// The action Command-Return runs: the one whose shortcut is ``KeyCombo/secondaryAction``, or
    /// else the second action, unless that one declares a shortcut of its own, such as Option-Return
    /// for a modifier action. The host and `FeatureHarness` both use this rule.
    public var secondary: Action? {
        if let declared = first(where: { $0.shortcut == .secondaryAction }) { return declared }
        guard count > 1, self[1].shortcut == nil else { return nil }
        return self[1]
    }
}
