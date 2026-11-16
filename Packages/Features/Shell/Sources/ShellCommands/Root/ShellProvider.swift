import Foundation
import Kit

/// The ">" prefix in root search. A query that starts with ">" belongs to this provider alone: root
/// search shows one row, the command in full as typed, and nothing runs until the user presses
/// Return on it. The prefix with no command after it shows a hint that runs nothing.
///
/// Return hands the text to Run Shell Command, so every run passes the host's checks: a link never
/// starts it, and the host refuses it in a panel session a link opened. The row is never remembered
/// or learned, so the command text never reaches root search's files.
final class ShellProvider: AsyncProvider {
    let namespace = ShellFeature.namespace
    let sectionTitle = Strings.Root.section
    /// Root sends this provider only the queries it takes over.
    let minimumQueryLength = Int.max
    let maximumRows = 1

    private let handOff: HandOff

    init(handOff: HandOff) {
        self.handOff = handOff
    }

    /// Reads the first byte. No allocation.
    func takesOver(_ query: String) -> Bool {
        RootQuery.claims(query)
    }

    /// The row is cheap to make and the user expects it at once.
    func debounce(for query: String) -> Duration {
        .zero
    }

    func results(for query: String) async throws -> [Row] {
        guard let text = RootQuery.commandText(in: query) else { return [] }
        return await Self.rows(for: text)
    }

    /// The one row for a command, made off the main thread because the check reads the whole text.
    @concurrent static func rows(for text: String) async -> [Row] {
        let id = ItemID(ShellFeature.namespace, "typed")
        switch ShellCommand.check(text) {
        case .success(let command):
            return [
                Row(
                    id: id, title: DisplayText.oneLine(command.trimmed),
                    subtitle: command.isHidden ? Strings.Root.runsHidden : Strings.Root.runs, icon: .symbol("terminal"),
                    payload: Payload(TypedCommand(text: command.text)), memory: .never)
            ]
        case .failure(.empty):
            return [
                Row(
                    id: ItemID(ShellFeature.namespace, "hint"), title: Strings.Root.hintTitle,
                    subtitle: Strings.Root.hint, icon: .symbol("terminal"), memory: .never)
            ]
        case .failure(let problem):
            // Only the start of a refused command shows: it may be a pasted page.
            let shown = DisplayText.oneLine(String(text.trimmingCharacters(in: .whitespaces).prefix(200)))
            return [
                Row(
                    id: id, title: shown.isEmpty ? Strings.Root.unnamed : shown,
                    subtitle: Strings.Root.problem(problem),
                    icon: .symbol("terminal"), memory: .never, subtitleColor: .red)
            ]
        }
    }

    /// Run in Shell on Return, Copy Command, and Open in Terminal on Command-Return. The text was
    /// checked when the row was made, and each command checks it again before it acts. A row that
    /// cannot run offers nothing. Copy Command comes second, so when the user turned Run Shell
    /// Command off and the host hides it, Return copies and never opens Terminal.
    func actions(for row: Row) -> [Action] {
        guard let typed = try? row.payload?.decode(TypedCommand.self) else { return [] }
        let trimmed = typed.text.trimmingCharacters(in: .whitespaces)
        return [
            Action.runCommand(
                ShellFeature.runCommandID, title: Strings.Actions.runInShell, icon: .symbol("terminal"),
                arguments: handOff.arguments(for: typed.text)
            ).with(id: "run-in-shell"),
            Action.copy(trimmed, title: Strings.Actions.copyCommand, hud: Strings.Actions.copiedCommand)
                .with(id: "copy-command").with(shortcut: .copy),
            Action.runCommand(
                ShellFeature.terminalCommandID, title: Strings.Actions.openInTerminal, icon: .symbol("apple.terminal"),
                arguments: handOff.arguments(for: typed.text)
            ).with(id: "open-in-terminal").with(shortcut: .secondaryAction),
        ]
    }
}

/// The payload of the typed command's row: the text as typed after the prefix.
nonisolated struct TypedCommand: Codable, Hashable, Sendable {
    var text: String
}
