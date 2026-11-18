import Foundation
import Kit

/// Shell Commands: a command typed after ">" in root search runs in the user's login shell, and its
/// output streams into a page, as in Alfred.
///
/// Nothing runs on a keystroke: the ">" row runs only when the user presses Return on it, and it
/// hands the text to Run Shell Command so the host's checks apply. Every command stays out of deep
/// links, none is a fallback, and a run asks for nothing. The command text and the output are never
/// logged. A run belongs to the feature, so it goes on when the panel closes; when it ends unseen, a
/// HUD or a toast says how.
///
/// The feature is on by default, as Alfred's ">" is. It does nothing until the user types ">" and
/// presses Return, it asks for no permission at activation, and links cannot run a command.
public final class ShellFeature: Feature {
    nonisolated static let featureID = "shell"
    nonisolated static let namespace = "shell"
    nonisolated static let runCommandID = ItemID.command(feature: featureID, command: "run")
    nonisolated static let terminalCommandID = ItemID.command(feature: featureID, command: "open-in-terminal")

    public static let manifest = FeatureManifest(
        id: featureID, name: Strings.featureName, icon: .symbol("terminal"), summary: Strings.summary,
        permissions: [PermissionNeed(.accessibility, reason: Strings.accessibilityReason)])

    let context: FeatureContext
    let history: ShellHistory
    let board: RunBoard
    let provider: ShellProvider
    let historyList: HistoryList
    let handOff = HandOff()
    /// Sent when a run starts or ends or the history changes, so Shell History reloads.
    let listChanges = ChangeSignal()

    /// Does no I/O. Services are chosen here and touch nothing until a command runs.
    public init(context: FeatureContext) {
        self.context = context
        history = ShellHistory(context: context, changes: listChanges)
        board = RunBoard(
            context: context, processes: context.service(ShellProcessesKey.self),
            system: context.service(ShellSystemKey.self), history: history, handOff: handOff, changes: listChanges)
        provider = ShellProvider(handOff: handOff)
        historyList = HistoryList(history: history, board: board, clock: context.clock, changes: listChanges)
    }

    public var commands: [Command] {
        [
            Command(
                id: "run", title: Strings.runCommand, icon: .symbol("terminal"), keywords: Strings.runKeywords,
                arguments: [CommandArgument(HandOff.commandArgument, placeholder: Strings.commandPlaceholder)],
                allowsDeepLinks: false
            ) { [self] context in
                try await run(context)
            },
            Command(
                id: "history", title: Strings.historyCommand, icon: .symbol("clock.arrow.circlepath"),
                keywords: Strings.historyKeywords, allowsDeepLinks: false
            ) { [historyList] _ in
                .push(historyList.page())
            },
            Command(
                id: "open-in-terminal", title: Strings.terminalCommand, icon: .symbol("apple.terminal"),
                arguments: [CommandArgument(HandOff.commandArgument, placeholder: Strings.commandPlaceholder)],
                showsInRoot: false, allowsDeepLinks: false
            ) { [self] context in
                try await openInTerminal(context)
            },
        ]
    }

    public var liveProviders: [LiveProvider] {
        [.async(provider)]
    }

    /// Settings reads the status again when the history file turns out to come from a newer version.
    public var declarationChanges: ChangeSignal? { history.statusChanges }

    public var status: FeatureStatus? {
        guard history.isReadOnly else { return nil }
        return FeatureStatus(.warning, Strings.Status.readOnlyTitle, message: Strings.Status.readOnlyMessage)
    }

    public var settingsPane: SettingsPane? {
        ShellSettingsPane.pane(history: history)
    }

    /// Reads the history file off the main thread. Nothing else: no process, no prompt, no stream.
    public func activate() async {
        history.reload()
    }

    /// Stops every command that is going on.
    public func deactivate() async {
        board.stopAll()
    }

    /// Waits until the history file was read.
    public func waitUntilReady() async {
        await history.loaded()
    }

    // MARK: Running

    /// Run Shell Command: runs the command now when the user typed it, and opens its page.
    private func run(_ context: ActionContext) async throws -> ActionOutcome {
        let decision = handOff.decide(context.launch, arguments: context.arguments)
        guard decision != .refuse else {
            throw ActionFailure(Strings.Failures.linkRefused, message: Strings.Failures.linkRefusedMessage)
        }
        let command = try Self.checked(HandOff.text(in: context.arguments))
        guard decision == .act else { return .showRoot(query: RootQuery.query(for: command)) }
        let run = try await board.start(command, reporter: context)
        return .push(board.page(for: run))
    }

    /// Open Command in Terminal: writes the command to a script only the user can read and run, and
    /// opens it with Terminal.
    private func openInTerminal(_ context: ActionContext) async throws -> ActionOutcome {
        let decision = handOff.decide(context.launch, arguments: context.arguments)
        guard decision != .refuse else {
            throw ActionFailure(Strings.Failures.linkRefused, message: Strings.Failures.linkRefusedMessage)
        }
        let command = try Self.checked(HandOff.text(in: context.arguments))
        guard decision == .act else { return .showRoot(query: RootQuery.query(for: command)) }
        let setup = try await board.setup()
        // Turned off meanwhile: nothing is written and Terminal is not asked.
        try Task.checkCancellation()
        let folder = context.storage.cacheDirectory.appending(
            path: TerminalScript.folderName, directoryHint: .isDirectory)
        let script = TerminalScript.newFile(in: folder)
        do {
            let text = try TerminalScript.text(
                command: command, shell: setup.shell, folder: setup.folder, script: script)
            try await TerminalScript.write(text, to: script)
        } catch .shellPath {
            throw ActionFailure(Strings.Failures.terminalFailed, message: Strings.Failures.terminalShellPath)
        } catch .write(let reason) {
            throw ActionFailure(Strings.Failures.terminalFailed, message: reason)
        }
        context.dismiss()
        try await context.workspace.open([script], withApplication: TerminalScript.terminalBundleID)
        return .close()
    }

    /// The command, or the failure that says why it cannot run.
    static func checked(_ text: String) throws -> ShellCommand {
        switch ShellCommand.check(text) {
        case .success(let command):
            return command
        case .failure(let problem):
            throw ActionFailure(Strings.Failures.title(problem), message: Strings.Failures.message(problem))
        }
    }
}
