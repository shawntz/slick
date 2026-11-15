import Foundation
import Kit

/// Makes a command for each script and runs it in its output mode.
///
/// Silent: the panel closes at once and the last line shows as a HUD when the script ends.
/// Compact: the last line shows as a toast. Inline: the first line becomes the command's subtitle
/// and shows as a toast. Full output: a page streams the output. List: a page shows the rows the
/// script prints. A script that fails shows the last line of its error output, with a button that
/// shows all of it.
///
/// Scripts run through the feature's own context, so a run started from any panel uses the same
/// process service, settings and clock.
final class ScriptCommands {
    private let context: FeatureContext
    private let subtitles: InlineSubtitles

    init(context: FeatureContext, subtitles: InlineSubtitles) {
        self.context = context
        self.subtitles = subtitles
    }

    func command(for script: Script) -> Command {
        let title = script.title
        let confirmation =
            script.metadata.needsConfirmation
            ? Confirmation(Strings.confirmRun(title), confirmTitle: Strings.confirmRunButton) : nil
        let fallback = script.acceptsTypedText ? Fallback { Strings.runFallback(title, text: $0) } : nil
        let keywords = [script.url.lastPathComponent, script.metadata.description].compactMap(\.self)
        let command = Command(
            id: script.commandID, title: title, subtitle: script.subtitle,
            icon: script.icon(home: context.storage.homeDirectory), keywords: keywords,
            arguments: script.commandArguments, confirmation: confirmation, fallback: fallback,
            liveSubtitle: script.mode == .inline ? inlineSubtitle(for: script) : nil,
            runPolicy: .concurrent
        ) { [self] context in
            try await run(script, context: context)
        }
        return command.withRowActions { [self] in rowActions(for: script) }
    }

    // MARK: - Running

    /// Runs a script in its mode. The action context gives what the user entered and the panel;
    /// everything else comes from the feature's context.
    func run(_ script: Script, context action: ActionContext) async throws -> ActionOutcome {
        let settings = RunSettings.read(context.settings, home: context.storage.homeDirectory)
        let request = script.request(arguments: script.processArguments(from: action.arguments), settings: settings)
        switch script.mode {
        case .fullOutput:
            let source = FullOutputSource(
                script: script, request: request, processes: processes, clock: context.clock, settings: settings)
            return .push(.detail(DetailPage(title: script.title, source: source)))
        case .list:
            let typed = [.fallback, .tabFromRoot].contains(action.launch) ? action.query : ""
            let source = ScriptListSource(
                script: script, processes: processes, settings: context.settings, home: settings.home,
                namespace: context.featureID)
            let empty = EmptyState(icon: script.icon(home: settings.home), title: Strings.noResults)
            return .push(
                .list(
                    ListPage(
                        source, title: script.title, searchPlaceholder: Strings.searchPlaceholder(script.title),
                        emptyState: empty, initialQuery: typed)))
        case .silent:
            return try await runSilent(script, request: request, settings: settings, context: action)
        case .compact, .inline:
            return try await runToEnd(script, request: request, settings: settings, context: action)
        }
    }

    /// Closes the panel at once and reports with a HUD when the script ends.
    private func runSilent(
        _ script: Script, request: ProcessRequest, settings: RunSettings, context: ActionContext
    ) async throws -> ActionOutcome {
        context.dismiss()
        let output: CapturedOutput
        do {
            output = try await ScriptExecution.capture(processes, request, limit: settings.outputLimit)
        } catch {
            guard let failure = ScriptExecution.failure(for: error, title: script.title, settings: settings) else {
                throw error
            }
            return .close(hud: .failure(failure.title))
        }
        guard output.exitCode == 0 else {
            return .close(hud: .failure(output.failureLine ?? Strings.failed(script.title)))
        }
        return .close(hud: OutputText.lastLine(output.output).map(HUD.success))
    }

    /// Reports with a toast, which the host draws as a HUD when the panel is closed. An inline
    /// script's first line also becomes its subtitle.
    private func runToEnd(
        _ script: Script, request: ProcessRequest, settings: RunSettings, context: ActionContext
    ) async throws -> ActionOutcome {
        let isInline = script.mode == .inline
        let output: CapturedOutput
        do {
            output = try await ScriptExecution.capture(processes, request, limit: settings.outputLimit)
        } catch {
            if isInline, let value = InlineSubtitles.value(for: error, title: script.title, settings: settings) {
                remember(value, for: script)
            }
            guard let failure = ScriptExecution.failure(for: error, title: script.title, settings: settings) else {
                throw error
            }
            throw failure
        }
        if isInline { remember(InlineSubtitles.value(for: output), for: script) }
        guard output.exitCode == 0 else {
            context.showToast(
                Toast(
                    .failure, output.failureLine ?? Strings.failed(script.title),
                    message: Strings.failedWithCode(output.exitCode),
                    action: ShowOutput.toastAction(title: script.title, output: output)))
            return .keepOpen
        }
        let line = isInline ? OutputText.firstLine(output.output) : OutputText.lastLine(output.output)
        context.showToast(.success(line ?? Strings.finished(script.title)))
        return .keepOpen
    }

    private var processes: any ProcessService { context.processes }

    private func remember(_ value: LiveSubtitle.Value, for script: Script) {
        subtitles.set(value, for: script.commandID)
        subtitles.signal(for: script.commandID).send()
    }

    // MARK: - Inline subtitles

    /// Runs the script off the main thread on its refresh time, but only when the user turned on
    /// automatic refresh for it. Otherwise it shows what the last manual run printed. A script that
    /// asks before it runs never runs by itself, whatever the setting holds.
    private func inlineSubtitle(for script: Script) -> LiveSubtitle? {
        guard let interval = script.metadata.refreshTime else { return nil }
        let (processes, settings, subtitles) = (context.processes, context.settings, subtitles)
        let home = context.storage.homeDirectory
        let id = script.commandID
        let mayRefresh = script.canRefreshByItself
        return .background(every: interval, changes: subtitles.signal(for: id)) {
            guard mayRefresh, settings[ScriptsSettings.refreshingInline].contains(id) else {
                return subtitles.value(for: id)
            }
            let run = RunSettings.read(settings, home: home)
            let value: LiveSubtitle.Value?
            do {
                let request = script.request(arguments: [], settings: run)
                value = InlineSubtitles.value(
                    for: try await ScriptExecution.capture(processes, request, limit: run.outputLimit))
            } catch {
                value = InlineSubtitles.value(for: error, title: script.title, settings: run)
            }
            if let value { subtitles.set(value, for: id) }
            return value
        }
    }

    // MARK: - Row actions

    /// The actions after Run on a script's row in root search.
    func rowActions(for script: Script) -> [Action] {
        var actions: [Action] = []
        if script.canRefreshByItself {
            let isOn = context.settings[ScriptsSettings.refreshingInline].contains(script.commandID)
            actions.append(refreshToggle(for: script, isOn: isOn))
        }
        actions.append(.openWith(script.url, title: Strings.editWith).with(id: "edit-with"))
        actions.append(.reveal([script.url]))
        actions.append(.copyPath(script.url))
        return actions
    }

    private func refreshToggle(for script: Script, isOn: Bool) -> Action {
        let id = script.commandID
        let (subtitles, settings) = (subtitles, context.settings)
        return Action(
            isOn ? Strings.turnOffRefresh : Strings.turnOnRefresh, id: "toggle-refresh",
            icon: .symbol(isOn ? "pause.circle" : "arrow.clockwise.circle")
        ) { context in
            var ids = settings[ScriptsSettings.refreshingInline]
            let turningOn = !ids.contains(id)
            if turningOn { ids.append(id) } else { ids.removeAll { $0 == id } }
            settings[ScriptsSettings.refreshingInline] = ids
            subtitles.signal(for: id).send()
            context.showToast(.success(turningOn ? Strings.refreshOn : Strings.refreshOff))
            return .keepOpen
        }
    }
}
