import Foundation
import Kit

/// How the harness runs handlers, applies outcomes and loads pages, following the host's rules.
extension FeatureHarness {
    func makeContext(
        query: String, arguments: CommandArguments = CommandArguments(), launch: LaunchSource, row: Row?
    ) -> ActionContext {
        ActionContext(
            feature: context, host: self, query: query, arguments: arguments, launch: launch, row: row,
            startedByLink: inLinkSession || launch == .deeplink)
    }

    func action(_ idOrTitle: String, in actions: [Action]) throws -> Action {
        guard
            let action = actions.first(where: { $0.id == idOrTitle }) ?? actions.first(where: { $0.title == idOrTitle })
        else {
            throw HarnessError.noSuchAction(idOrTitle)
        }
        return action
    }

    /// The actions the host would show, with the issues the validator finds in them noted for
    /// ``issues``.
    func shown(_ actions: [Action]) -> [Action] {
        note(FeatureValidator.validate(actions: actions, manifest: F.manifest))
        return actions.filter { action in action.requiresCommand.map { !unavailableCommands.contains($0) } ?? true }
    }

    func note(_ issues: [FeatureIssue]) {
        for issue in issues where !seenIssues.contains(issue) {
            seenIssues.append(issue)
        }
    }

    func checkPermissions(_ permissions: [Permission]) async throws {
        var missing = permissions.filter { !fakes.permissions.status(of: $0).isGranted }
        if grantsMissingPermissions {
            for permission in missing {
                // As the host's card does, a grant also tells the feature, when its manifest lists it.
                if await fakes.permissions.request(permission).isGranted { await announceGrant(of: permission) }
            }
            missing = missing.filter { !fakes.permissions.status(of: $0).isGranted }
        }
        if !missing.isEmpty { throw HarnessError.permissionRequired(missing) }
    }

    /// Checks permissions, asks the confirmation, runs the handler under its policy, runs it again
    /// once if it asked for a permission that was then granted, and applies the outcome.
    @discardableResult
    func execute(
        requires: [Permission], confirmation: Confirmation?, policy: RunPolicy, key: String, context: ActionContext,
        handler: @escaping Action.Handler
    ) async throws -> ActionOutcome {
        try await checkPermissions(requires)
        if let confirmation {
            confirmations.append(confirmation)
            guard confirmationAnswer else { return .keepOpen }
        }
        var outcome = try await runHandler(handler, context: context, policy: policy, key: key)
        if case .needsPermission(let permission) = outcome {
            // The host shows its card; only pressing Grant asks the system.
            guard grantsMissingPermissions, await fakes.permissions.request(permission).isGranted else {
                throw HarnessError.permissionRequired([permission])
            }
            await announceGrant(of: permission)
            outcome = try await runHandler(handler, context: context, policy: policy, key: key)
        }
        try await finish(outcome)
        return outcome
    }

    private func runHandler(
        _ handler: @escaping Action.Handler, context: ActionContext, policy: RunPolicy, key: String
    ) async throws -> ActionOutcome {
        do {
            switch policy {
            case .concurrent:
                return try await handler(context)
            case .dropWhileRunning:
                guard running.insert(key).inserted else {
                    droppedRuns.append(key)
                    return .keepOpen
                }
                defer { running.remove(key) }
                return try await handler(context)
            case .serial:
                let previous = serialTail
                let run = Task { @MainActor in
                    await previous?.value
                    return try await handler(context)
                }
                serialTail = Task { _ = try? await run.value }
                // A caller that is cancelled cancels the handler, as turning the feature off does in
                // the host, so a test can play that through run(_:).
                return try await withTaskCancellationHandler {
                    try await run.value
                } onCancel: {
                    run.cancel()
                }
            }
        } catch {
            if throwsActionErrors { throw error }
            if !(error is CancellationError) { showFailure(error) }
            return .keepOpen
        }
    }

    /// What the host shows for a thrown error.
    private func showFailure(_ error: any Error) {
        actionErrors.append(error)
        let described = error as? any LocalizedError
        let title = described?.errorDescription ?? String(describing: error)
        if isClosed {
            huds.append(.failure(title))
        } else {
            let toast = Toast.failure(title, message: described?.failureReason)
            toasts.append(toast)
            visibleToast = toast
        }
    }

    private func finish(_ outcome: ActionOutcome) async throws {
        switch outcome {
        case .close(let hud):
            let wasOpen = !isClosed
            isClosed = true
            visibleToast = nil
            if wasOpen { tellPagesThePanelClosed() }
            if let hud { huds.append(hud) }
        case .keepOpen:
            break
        case .push(let page):
            try await open(page)
        case .replace(let page):
            pop()
            try await open(page)
        case .pop:
            pop()
        case .popToRoot:
            pages.removeAll()
        case .showRoot(let query):
            pages.removeAll()
            rootQueries.append(query)
        case .run(let id, let arguments):
            commandRuns.append(CommandRun(id: id, arguments: arguments))
            if unavailableCommands.contains(id) {
                showToast(.failure("This command is not available"), id: ToastID(0))
            } else if let command = feature.commands.first(where: { $0.itemID(feature: F.manifest.id) == id }) {
                try await run(command.id, arguments: arguments, launch: .command)
            }
        case .needsPermission(let permission):
            throw HarnessError.permissionRequired([permission])
        case .showLargeType(let text):
            let wasOpen = !isClosed
            isClosed = true
            visibleToast = nil
            if wasOpen { tellPagesThePanelClosed() }
            largeTypeTexts.append(text)
        }
        guard let state = page else {
            reloadRequested = false
            queryChangedByAction = false
            return
        }
        if queryChangedByAction {
            queryChangedByAction = false
            try await applyQuery(state)
        }
        if reloadRequested || isStale(state) {
            reloadRequested = false
            try await load(state, reason: .reload)
        }
    }

    /// Filters or loads for the page's current query, as typing does.
    func applyQuery(_ state: PageState) async throws {
        guard let source = state.listSource else { return }
        if source.filtering == .host {
            state.filterLoadedSections()
            state.keepSelectionVisible()
        } else {
            try await load(state, reason: .query)
        }
    }

    /// True when the page's source signalled or one of its settings changed since its last load.
    func isStale(_ state: PageState) -> Bool {
        guard let source = state.listSource else { return false }
        return (source.changes?.generation ?? 0) != state.loadedGeneration
            || source.reloadsOnSettings.map(context.settings.storage(of:)) != state.loadedSettings
    }

    func load(_ state: PageState, reason: LoadReason) async throws {
        switch state.page {
        case .list, .grid:
            try await loadList(state, reason: reason)
        case .detail(let detailPage):
            state.detail = Detail()
            for try await update in detailPage.source.start() {
                state.detail.apply(update)
            }
        case .form:
            break
        }
    }

    private func loadList(_ state: PageState, reason: LoadReason) async throws {
        guard let source = state.listSource else { throw HarnessError.wrongPage(expected: "list or grid") }
        let hostFilters = source.filtering == .host
        state.loadedGeneration = source.changes?.generation ?? 0
        state.loadedSettings = source.reloadsOnSettings.map(context.settings.storage(of:))
        let request = ListRequest(query: hostFilters ? "" : state.query, filter: state.filter, reason: reason)
        let result = try await source.load(request)
        if let dropdown = result.filter {
            state.dropdown = dropdown
            if !dropdown.options.contains(where: { $0.id == state.filter }), state.filter != dropdown.defaultID {
                state.filter = dropdown.defaultID
                try await loadList(state, reason: .filter)
                return
            }
        }
        state.loadedSections = result.sections
        state.refreshAfter = result.refreshAfter
        state.nextPage = hostFilters ? nil : result.nextPage
        state.notice = result.notice
        state.emptyState = result.emptyState ?? state.pageEmptyState
        note(FeatureValidator.validate(actions: state.emptyState?.actions ?? [], manifest: F.manifest))
        if hostFilters {
            var entries: [FuzzyEntry] = []
            var positions: [(section: Int, row: Int)] = []
            for (sectionIndex, section) in result.sections.enumerated() {
                for (rowIndex, row) in section.rows.enumerated() {
                    entries.append(FuzzyEntry(title: row.title, keywords: row.keywords))
                    positions.append((sectionIndex, rowIndex))
                }
            }
            state.index = await context.fuzzyIndex.makeIndex(entries)
            state.positions = positions
            state.filterLoadedSections()
        } else {
            state.sections = result.sections.filter { $0.isVisible(forQuery: state.query) && !$0.rows.isEmpty }
        }
        state.keepSelectionVisible()
    }
}
