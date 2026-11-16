import Foundation
import Kit

/// Decides whether a command that runs or opens a shell command may act at once, from how it was
/// started.
///
/// The feature's own rows and pages hand the command text to its commands with a token only this
/// feature instance knows, so the host's checks apply to every run: a link never runs one, and the
/// host refuses commands that stay out of links in a panel session a link opened. Another feature
/// that hands text to these commands gets no run. The text goes back into root search behind the
/// prefix instead, where the user reads it and presses Return.
nonisolated struct HandOff: Sendable {
    /// The argument that holds the command text.
    static let commandArgument = "command"
    /// The undeclared argument that carries the token.
    static let tokenArgument = "handOff"

    /// What a command does for one launch.
    enum Decision: Hashable, Sendable {
        /// Run, or open in Terminal, now.
        case act
        /// Put the text in root search behind the prefix and let the user press Return.
        case confirmInRoot
        /// Refuse, as for a link.
        case refuse
    }

    let token: String

    init(token: String = UUID().uuidString) {
        self.token = token
    }

    /// The arguments the feature's own actions pass.
    func arguments(for text: String) -> [String: String] {
        [Self.commandArgument: text, Self.tokenArgument: token]
    }

    /// The command text a run received, or an empty string.
    static func text(in arguments: CommandArguments) -> String {
        arguments.values[commandArgument] ?? ""
    }

    /// What to do for a launch.
    ///
    /// A typed root query, a page and a hotkey act: the user typed the command in the search field
    /// and pressed Return. A hand-off acts only with this instance's token. A link is refused.
    /// Everything else puts the text in root search.
    func decide(_ launch: LaunchSource, arguments: CommandArguments) -> Decision {
        switch launch {
        case .deeplink:
            .refuse
        case .root, .page, .hotkey:
            .act
        case .command:
            arguments.values[Self.tokenArgument] == token ? .act : .confirmInRoot
        default:
            .confirmInRoot
        }
    }
}
