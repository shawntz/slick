import Foundation
import Kit
import KitTemplates

/// Every action the feature offers: on quicklink rows, on their commands in root search, on a typed
/// address, and for a selection in another app. Each is built from an ID and looks the quicklink up
/// again when it runs, so it never acts on a stale copy.
final class QuicklinkActions {
    /// Where a quicklink's actions are shown, which decides what comes first and what is left out.
    enum Place {
        /// Search Quicklinks: Return opens.
        case list
        /// The page Edit Quicklink shows: Return edits.
        case editPicker
        /// A quicklink without arguments in root search: Return opens.
        case catalog
        /// A quicklink with arguments in root search, after the host's Run.
        case commandRow
    }

    private unowned let feature: QuicklinksFeature

    init(feature: QuicklinksFeature) {
        self.feature = feature
    }

    // MARK: - Quicklinks

    func rowActions(for entry: QuicklinkEntry, on place: Place) -> [Action] {
        var actions: [Action] = []
        if place == .editPicker { actions.append(edit(entry)) }
        // On a command row the host's Run opens the quicklink with the values typed in the search bar.
        if place != .commandRow { actions.append(open(entry)) }
        // With arguments, a list row's Open asks for the values and the app, so Open With is only
        // offered where the values are known.
        if entry.arguments.isEmpty || place == .commandRow { actions.append(openWith(entry)) }
        actions.append(copyLink(entry))
        if place != .editPicker { actions.append(edit(entry)) }
        actions.append(duplicate(entry))
        if entry.takesQuery, entry.isEnabled, feature.defaultEngine?.id != entry.id {
            actions.append(setAsDefault(entry))
        }
        actions.append(toggle(entry))
        actions.append(delete(entry))
        if place == .list || place == .editPicker { actions.append(createAction) }
        return actions
    }

    var createAction: Action {
        Action(
            Strings.createQuicklink, id: "create", icon: .symbol("plus"), shortcut: .new, section: Strings.manageSection
        ) { [unowned feature] _ in
            .push(.form(feature.forms.create()))
        }
    }

    /// Opens a quicklink without arguments at once. One with arguments pushes a form for them.
    private func open(_ entry: QuicklinkEntry) -> Action {
        let id = entry.id
        let needsValues = !entry.arguments.isEmpty
        return Action(
            Strings.open, id: "open", icon: .symbol("arrow.up.forward.app"),
            requires: needsValues ? [] : entry.requires
        ) { [unowned feature] context in
            let current = try feature.current(id)
            if needsValues { return .push(.form(feature.forms.arguments(for: current))) }
            return try await feature.open(current, context: context, values: [:])
        }
    }

    /// The apps that can open the link, rendered when the submenu opens with the values typed so far.
    private func openWith(_ entry: QuicklinkEntry) -> Action {
        let id = entry.id
        return .openWith(
            title: Strings.openWith,
            resolving: { [unowned feature] context in
                guard let current = feature.entry(id: id),
                    let url = try? await feature.link(for: current, context: context, values: context.arguments.values)
                else { return [] }
                return [url]
            })
    }

    /// Copies the link as written, placeholders included, so it can be shared or pasted into a form.
    private func copyLink(_ entry: QuicklinkEntry) -> Action {
        Action.copy(entry.quicklink.link, title: Strings.copyLink, hud: Strings.copiedLink, shortcut: .copy)
            .with(id: "copy-link")
    }

    private func edit(_ entry: QuicklinkEntry) -> Action {
        let id = entry.id
        return Action(
            Strings.edit, id: "edit", icon: .symbol("pencil"), shortcut: .edit, section: Strings.manageSection
        ) { [unowned feature] _ in
            .push(.form(feature.forms.edit(try feature.current(id).quicklink)))
        }
    }

    private func duplicate(_ entry: QuicklinkEntry) -> Action {
        let id = entry.id
        return Action(
            Strings.duplicate, id: "duplicate", icon: .symbol("plus.square.on.square"), shortcut: .duplicate,
            section: Strings.manageSection
        ) { [unowned feature] _ in
            .push(.form(feature.forms.duplicate(try feature.current(id).quicklink)))
        }
    }

    private func setAsDefault(_ entry: QuicklinkEntry) -> Action {
        let id = entry.id
        return Action(Strings.setAsDefault, id: "set-default", icon: .symbol("star"), section: Strings.manageSection) {
            [unowned feature] context in
            let current = try feature.current(id)
            feature.context.settings[QuicklinksSettings.defaultSearch] = current.id
            context.showToast(.success(Strings.defaultEngineSet(current.quicklink.name)))
            return .keepOpen
        }
    }

    private func toggle(_ entry: QuicklinkEntry) -> Action {
        let id = entry.id
        let turnsOn = !entry.quicklink.isEnabled
        return Action(
            turnsOn ? Strings.turnOn : Strings.turnOff, id: "toggle", icon: .symbol("power"),
            section: Strings.manageSection
        ) { [unowned feature] context in
            let current = try feature.current(id)
            try await feature.setEnabled(turnsOn, id: current.id)
            let name = current.quicklink.name
            context.showToast(.success(turnsOn ? Strings.turnedOn(name) : Strings.turnedOff(name)))
            return .keepOpen
        }
    }

    private func delete(_ entry: QuicklinkEntry) -> Action {
        let id = entry.id
        let quicklink = entry.quicklink
        let confirmation = Confirmation(
            Strings.deleteTitle(quicklink.name),
            message: quicklink.isBuiltIn ? Strings.deleteBuiltInMessage : Strings.deleteOwnMessage,
            confirmTitle: Strings.deleteConfirm, isDestructive: true)
        return Action(
            Strings.delete, id: "delete", icon: .symbol("trash"), shortcut: .remove, style: .destructive,
            section: Strings.manageSection, confirmation: confirmation
        ) { [unowned feature] context in
            try await feature.remove(id: id)
            if let row = context.row { context.usage.forget(row.id) }
            context.showToast(.success(Strings.deletedQuicklink))
            return .keepOpen
        }
    }

    // MARK: - A typed address

    /// Open, Open With and Copy Link for a typed address. Save as Quicklink comes with the universal
    /// actions, because the row stands for its link.
    func addressActions(for url: URL) -> [Action] {
        [
            openLink(url).with(title: Strings.open).with(id: "open"),
            .openWith(url, title: Strings.openWith),
            Action.copy(url.absoluteString, title: Strings.copyLink, hud: Strings.copiedLink, shortcut: .copy)
                .with(id: "copy-link"),
        ]
    }

    // MARK: - Universal actions

    /// For selected text: search the web with the default search engine or any other, and open the
    /// text when it is a web address.
    func universalActions(forText text: String) -> [Action] {
        var actions: [Action] = []
        if let address = AddressDetector.detect(text) { actions.append(openLink(address.url)) }
        let query = SearchText.prepare(text)
        guard !query.isEmpty, feature.defaultEngine != nil else { return actions }
        actions.append(
            Action(Strings.searchTheWeb, id: "search-web", icon: .symbol("magnifyingglass")) {
                [unowned feature] context in
                guard let engine = feature.defaultEngine else {
                    throw ActionFailure(Strings.noSearchEngine, message: Strings.noSearchEngineMessage)
                }
                return try await feature.search(query, with: engine, context: context)
            })
        actions.append(
            .submenu(Strings.searchWith, id: "search-with", icon: .symbol("magnifyingglass.circle")) {
                [unowned feature] _ in
                feature.searchEngines.map { engine in
                    Action(engine.quicklink.name, id: "search-with." + engine.id, icon: engine.icon) {
                        context in
                        try await feature.search(query, with: engine, context: context)
                    }
                }
            })
        return actions
    }

    /// For a selected web link: open it, or save it as a quicklink.
    func universalActions(forURL url: URL) -> [Action] {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return [] }
        let name = url.host().map(QuicklinkRows.siteName) ?? ""
        return [
            openLink(url),
            Action(Strings.saveAsQuicklink, id: "save-quicklink", icon: .symbol("link.badge.plus")) {
                [unowned feature] _ in
                .push(.form(feature.forms.create(link: url.absoluteString, name: name)))
            },
        ]
    }

    private func openLink(_ url: URL) -> Action {
        Action(Strings.openLink, id: "open-link", icon: .symbol("safari")) { [unowned feature] context in
            try await feature.open(url, with: nil, context: context)
            return .close()
        }
    }
}

/// Selected text made fit for a search: one line, no surrounding space, at most 1,000 characters.
nonisolated enum SearchText {
    static let maximumLength = 1000

    /// Reads only as far as it needs, so a selection of many megabytes costs no more than a short
    /// one when the action panel opens.
    static func prepare(_ text: String) -> String {
        var result = ""
        var count = 0
        var needsSpace = false
        for character in text {
            if character.isWhitespace {
                needsSpace = count > 0
                continue
            }
            if needsSpace {
                guard count + 1 < maximumLength else { break }
                result.append(" ")
                count += 1
                needsSpace = false
            }
            result.append(character)
            count += 1
            if count == maximumLength { break }
        }
        return result
    }
}

extension QuicklinksFeature {
    /// The quicklink with this ID now. Throws when it was deleted after its action was made.
    func current(_ id: String) throws -> QuicklinkEntry {
        guard let entry = entry(id: id) else { throw ActionFailure(Strings.quicklinkGone) }
        return entry
    }

    /// Searches for text with a quicklink that takes the typed text.
    func search(_ text: String, with engine: QuicklinkEntry, context: ActionContext) async throws -> ActionOutcome {
        guard let first = engine.arguments.first else { throw ActionFailure(Strings.quicklinkGone) }
        return try await open(engine, context: context, values: [first.key: text])
    }
}
