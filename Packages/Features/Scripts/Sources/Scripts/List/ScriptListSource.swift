import Foundation
import Kit

/// The page of a list script. The script runs with the query as `$1` each time the query settles,
/// again after its `rerun` delay, and with the session variables it returned in its environment.
/// The host cancels a run when the query changes or the page closes, which ends the script.
final class ScriptListSource: ListSource {
    /// How long the query must be still before the script runs.
    static let debounce = Duration.milliseconds(120)

    private let script: Script
    private let processes: any ProcessService
    private let settings: FeatureSettings
    private let home: URL
    private let namespace: String
    /// Variables the script returned, passed back on its later runs in this page.
    private(set) var sessionVariables: [String: String] = [:]

    init(script: Script, processes: any ProcessService, settings: FeatureSettings, home: URL, namespace: String) {
        self.script = script
        self.processes = processes
        self.settings = settings
        self.home = home
        self.namespace = namespace
    }

    var filtering: ListFiltering { .custom(debounce: Self.debounce) }

    func load(_ request: ListRequest) async throws -> ListResult {
        let run = RunSettings.read(settings, home: home)
        let processRequest = script.request(arguments: [request.query], variables: sessionVariables, settings: run)
        let output: CapturedOutput
        do {
            output = try await ScriptExecution.capture(processes, processRequest, limit: run.outputLimit)
        } catch {
            guard let failure = ScriptExecution.failure(for: error, title: script.title, settings: run) else {
                throw error
            }
            return failed(failure.title, message: failure.message, output: nil)
        }
        try Task.checkCancellation()
        guard output.exitCode == 0 else {
            let message = OutputText.lastLines(output.errorOutput, count: 5) ?? Strings.failedWithCode(output.exitCode)
            return failed(Strings.listFailed(script.title), message: message, output: output)
        }
        let source = FilterOutput.Source(
            namespace: namespace, commandID: script.commandID, folder: script.folder, home: home, query: request.query)
        let page: FilterPage
        do {
            page = try await FilterOutput.parse(output.stdout, source: source)
        } catch {
            return failed(Strings.listFailed(script.title), message: error.message, output: output)
        }
        try Task.checkCancellation()
        sessionVariables.merge(page.variables) { _, new in new }
        let notice =
            page.notices.isEmpty
            ? nil : Notice(icon: .symbol("exclamationmark.triangle"), title: page.notices.joined(separator: " "))
        return ListResult(rows: page.rows, refreshAfter: page.rerun, notice: notice)
    }

    /// Built from the row's payload alone. Return acts on the item's argument as the script's
    /// filter action says; Return with modifiers acts on that modifier's argument.
    func actions(for row: Row) -> [Action] {
        guard let item = try? row.payload?.decode(FilterItem.self) else { return [] }
        var actions: [Action] = []
        var primaryCopies: String?
        if item.isValid {
            let (action, copied) = argumentAction(item.arguments, fallback: item.title)
            actions.append(action)
            primaryCopies = copied
        } else if let completion = item.autocomplete {
            actions.append(
                Action(Strings.complete, id: "complete", icon: .symbol("arrow.right.to.line")) { context in
                    context.setQuery(completion)
                    return .keepOpen
                })
        }
        for modifier in item.modifiers.sorted(by: { $0.modifiers.rawValue < $1.modifiers.rawValue })
        where modifier.isValid {
            let shortcut = KeyCombo(.return, modifier.modifiers)
            let (action, _) = argumentAction(modifier.arguments ?? item.arguments, fallback: item.title)
            actions.append(
                action.with(title: Strings.withModifiers(action.title, modifier.modifiers))
                    .with(id: "modifier." + shortcut.description).with(shortcut: shortcut))
        }
        let copyText = item.copyText ?? (item.arguments.isEmpty ? item.title : item.arguments.joined(separator: "\n"))
        if copyText != primaryCopies {
            actions.append(.copy(copyText, title: Strings.copyArgument, shortcut: .copy).with(id: "copy-text"))
        }
        if let url = row.quickLookURL { actions.append(.quickLook(url)) }
        if item.isFile, let path = item.arguments.first, let url = FilterOutput.fileURL(path, home: home) {
            actions.append(.reveal([url]))
        }
        return actions
    }

    /// The action for an argument under the script's filter action, and the text it copies, if it
    /// copies.
    private func argumentAction(_ arguments: [String], fallback: String) -> (Action, String?) {
        let values = arguments.isEmpty ? [fallback] : arguments
        let text = values.joined(separator: "\n")
        switch script.metadata.filterAction {
        case .copy:
            return (.copy(text, title: Strings.copyArgument), text)
        case .paste:
            return (.paste(text, title: Strings.pasteArgument), nil)
        case .open:
            let urls = values.compactMap { openableURL($0, strict: false) }
            guard !urls.isEmpty else { return (.copy(text, title: Strings.copyArgument), text) }
            return (.open(urls, title: Strings.openArgument), nil)
        case .auto:
            let urls = values.compactMap { openableURL($0, strict: true) }
            guard !urls.isEmpty, urls.count == values.count else {
                return (.copy(text, title: Strings.copyArgument), text)
            }
            return (.open(urls, title: Strings.openArgument), nil)
        }
    }

    /// A path, or a URL. Strict accepts only `http` and `https` among URLs, so `auto` never hands
    /// an unusual scheme to another app; `open` accepts any scheme.
    private func openableURL(_ text: String, strict: Bool) -> URL? {
        if let file = FilterOutput.fileURL(text, home: home) { return file }
        guard let url = URL(string: text.trimmed), let scheme = url.scheme?.lowercased() else { return nil }
        if strict { return ["http", "https"].contains(scheme) && url.host() != nil ? url : nil }
        return scheme.count > 1 ? url : nil
    }

    private func failed(_ title: String, message: String?, output: CapturedOutput?) -> ListResult {
        var actions: [Action] = []
        if let output {
            actions.append(ShowOutput.action(title: script.title, output: output))
        }
        return ListResult(
            rows: [],
            emptyState: EmptyState(
                icon: .symbol("exclamationmark.triangle"), title: title, message: message, actions: actions))
    }
}
