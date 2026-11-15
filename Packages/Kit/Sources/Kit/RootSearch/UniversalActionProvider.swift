import Foundation

/// Actions a feature offers for text, a URL or files: what the user selected in the frontmost app
/// when they pressed the selection hotkey, or what a row in any list stands for (see
/// ``Row/represents``).
///
/// The host asks every provider whose ``accepts`` matches and shows the actions together, in a
/// "Universal Actions" section when they follow a row's own actions. It prefixes each action's ID
/// with the feature's ID, so IDs only need to be unique within the feature. Each action receives an
/// ``ActionContext`` whose query is the selection as text.
public struct UniversalActionProvider: Sendable {
    /// The kinds of selection this provider handles.
    public var accepts: SelectionKinds
    /// The actions for one selection. Cheap, like ``RowActionProvider/actions(for:)``.
    public var actions: @MainActor @Sendable (Selection) -> [Action]

    public init(accepts: SelectionKinds, actions: @escaping @MainActor @Sendable (Selection) -> [Action]) {
        self.accepts = accepts
        self.actions = actions
    }

    /// Actions for selected text.
    public static func text(_ actions: @escaping @MainActor @Sendable (String) -> [Action]) -> UniversalActionProvider {
        UniversalActionProvider(accepts: .text) { selection in
            if case .text(let text) = selection { return actions(text) }
            return []
        }
    }

    /// Actions for a selected URL.
    public static func url(_ actions: @escaping @MainActor @Sendable (URL) -> [Action]) -> UniversalActionProvider {
        UniversalActionProvider(accepts: .url) { selection in
            if case .url(let url) = selection { return actions(url) }
            return []
        }
    }

    /// Actions for selected files and folders.
    public static func files(_ actions: @escaping @MainActor @Sendable ([URL]) -> [Action]) -> UniversalActionProvider {
        UniversalActionProvider(accepts: .files) { selection in
            if case .files(let urls) = selection { return actions(urls) }
            return []
        }
    }
}
