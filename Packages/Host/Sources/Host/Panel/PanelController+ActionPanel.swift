import AppKit
import Kit
import KitHosting
import LauncherUI

/// The action panel on Command-K and the host's own entries for root rows.
extension PanelController {
    /// Opens the action panel for the top page's target: the toast's button when one shows, the
    /// row's entries, universal actions for what the row stands for that the row does not already
    /// offer under the same title, then the host's own entries for a root row.
    public func openActionPanel() {
        guard let target = top.target else { return }
        let entries = actionPanelEntries(for: target)
        guard !entries.isEmpty else { return }
        showActionCard(entries, target: target)
    }

    /// Every entry the action panel shows for a target, in order.
    public func actionPanelEntries(for target: ActionTarget) -> [ActionEntry] {
        var entries: [ActionEntry] = []
        if let visible = toasts.visible, let action = visible.toast.action, let origin = visible.origin {
            entries.append(ActionEntry(title: action.title, kind: .toast(action, origin)))
        }
        let split = min(target.universalInsertIndex, target.entries.count)
        entries += target.entries[..<split]
        if let selection = target.row?.represents {
            // The row's own source knows its item best: a universal action with the title of one of
            // the row's entries would show the same choice twice.
            let own = Set(target.entries.map(\.title))
            entries += universalEntries(for: selection, target: target).filter { !own.contains($0.title) }
        }
        entries += target.entries[split...]
        if target.isRoot, let row = target.row { entries += hostEntries(for: row) }
        entries += target.panelExtras
        return entries
    }

    /// Universal actions from every feature that is on, with IDs prefixed by the feature ID.
    func universalEntries(for selection: Selection, target: ActionTarget) -> [ActionEntry] {
        var entries: [ActionEntry] = []
        for feature in runtime.enabledFeatures {
            for provider in feature.universalActions where provider.accepts.contains(selection.kind) {
                for var action in runtime.visible(provider.actions(selection)) {
                    action.id = feature.id + "." + action.id
                    var entry = ActionEntry(
                        action, featureID: feature.id, context: feature.context, section: HostStrings.universalActions)
                    entry.query = selection.text
                    entries.append(entry)
                }
            }
        }
        return entries
    }

    /// The host's entries for a root row: favorites, alias, hotkey, ranking and, for a command, its
    /// switch.
    func hostEntries(for row: Row) -> [ActionEntry] {
        let preferences = runtime.preferences
        let section = HostStrings.itemActions
        var entries = [
            preferences.isFavorite(row.id)
                ? ActionEntry(
                    title: HostStrings.removeFromFavorites, icon: .symbol("star.slash"), section: section,
                    kind: .host(.removeFavorite))
                : ActionEntry(
                    title: HostStrings.addToFavorites, icon: .symbol("star"), section: section,
                    kind: .host(.addFavorite)),
            ActionEntry(
                title: preferences.aliases[row.id] == nil ? HostStrings.setAlias : HostStrings.changeAlias,
                icon: .symbol("character.cursor.ibeam"), section: section, kind: .host(.setAlias)),
            ActionEntry(
                title: preferences.hotkeys[row.id] == nil ? HostStrings.setHotkey : HostStrings.changeHotkey,
                icon: .symbol("command"), section: section, kind: .host(.setHotkey)),
            ActionEntry(
                title: HostStrings.resetRanking, icon: .symbol("arrow.counterclockwise"), section: section,
                kind: .host(.resetRanking)),
        ]
        if row.id.namespace == ItemID.ReservedNamespace.command, runtime.command(row.id) != nil {
            entries.append(
                ActionEntry(
                    title: HostStrings.disableCommand, icon: .symbol("nosign"), isDestructive: true, section: section,
                    kind: .host(.disableCommand)))
        }
        return entries
    }

    // MARK: The card

    func showActionCard(_ entries: [ActionEntry], target: ActionTarget) {
        actionEntries = entries
        actionTarget = target
        // A filter left from the last opening would hide entries: clear it before applying.
        (actionCard.focusView as? NSTextField)?.stringValue = ""
        actionCard.apply(cardContent(entries, target: target))
        surface.present(actionCard)
        actionCard.selectItem(at: 0)
    }

    /// The card's sections: consecutive entries with the same section share a heading.
    func cardContent(_ entries: [ActionEntry], target: ActionTarget?) -> ActionCardContent {
        var sections: [ActionSection] = []
        let primaryIndex = entries.firstIndex { entry in
            if case .toast = entry.kind { return false }
            return true
        }
        for (index, entry) in entries.enumerated() {
            var keys = entry.shortcut.map(RowMapper.keycaps) ?? []
            if keys.isEmpty, index == primaryIndex, target != nil { keys = ["↩"] }
            let item = ActionItem(
                id: String(index), title: entry.title, icon: rowMapper.cardIcon(entry.icon), keys: keys,
                isDestructive: entry.isDestructive)
            if let last = sections.indices.last, sections[last].title == entry.section {
                sections[last].items.append(item)
            } else {
                sections.append(ActionSection(title: entry.section, items: [item]))
            }
        }
        return ActionCardContent(sections: sections, placeholder: HostStrings.actionSearchPlaceholder)
    }

    /// Runs the card entry the user chose. A submenu replaces the card's entries.
    func activateCardItem(_ item: ActionItem) {
        guard let index = Int(item.id), actionEntries.indices.contains(index), let target = actionTarget else { return }
        let entry = actionEntries[index]
        if case .action(let action, _, _) = entry.kind, case .submenu = action.kind {
            run(entry, target: target)
            return
        }
        surface.dismissOverlay()
        run(entry, target: target)
    }

    /// Loads a submenu and shows its entries in the card.
    func openSubmenu(_ action: Action, featureID: String, context: FeatureContext, target: ActionTarget, query: String)
    {
        let origin = RunOrigin(
            featureID: featureID, feature: context, query: query, launch: target.launch, row: target.row)
        Task { [weak self] in
            guard let self else { return }
            let actions = runtime.visible(await runtime.pipeline.loadSubmenu(action, origin: origin))
            let entries = actions.map { ActionEntry($0, featureID: featureID, context: context, section: action.title) }
            guard !entries.isEmpty else { return }
            showActionCard(entries, target: target)
        }
    }

    // MARK: Host entries

    func perform(_ entry: HostEntry, target: ActionTarget) {
        guard let row = target.row else { return }
        let preferences = runtime.preferences
        switch entry {
        case .addFavorite:
            preferences.setFavorites(preferences.favorites + [row.id])
            showHostToast(HostStrings.addedToFavorites)
        case .removeFavorite:
            preferences.setFavorites(preferences.favorites.filter { $0 != row.id })
            showHostToast(HostStrings.removedFromFavorites)
        case .resetRanking:
            rootSource.forget(row.id)
            showHostToast(HostStrings.rankingReset)
        case .disableCommand:
            preferences.setEnabled(false, command: row.id)
            rootPage.reload()
            showHostToast(HostStrings.commandDisabled)
        case .setAlias:
            push(aliasPrompt(for: row))
        case .setHotkey:
            push(hotkeyPrompt(for: row))
        }
    }

    private func aliasPrompt(for row: Row) -> PromptPageController {
        let preferences = runtime.preferences
        let current = preferences.aliases[row.id]
        return PromptPageController(
            title: HostStrings.aliasPromptTitle(row.title), placeholder: HostStrings.aliasPlaceholder,
            initialText: current ?? "", symbolName: "character.cursor.ibeam",
            hint: current.map(HostStrings.currentValue) ?? HostStrings.promptEmptyHint
        ) { [weak self] text in
            preferences.setAlias(text, for: row.id)
            self?.pop()
            self?.showHostToast(text.isEmpty ? HostStrings.aliasRemoved : HostStrings.aliasSaved)
            return nil
        }
    }

    private func hotkeyPrompt(for row: Row) -> HotkeyPromptPageController {
        let preferences = runtime.preferences
        let current = preferences.hotkeys[row.id]
        return HotkeyPromptPageController(
            title: HostStrings.hotkeyPromptTitle(row.title), current: current,
            hint: current.map { HostStrings.currentValue($0.displayString) } ?? HostStrings.promptEmptyHint
        ) { [weak self] combo in
            do {
                try preferences.setHotkey(combo, for: row.id)
            } catch HotkeyError.conflict(let conflicts) {
                return HostStrings.hotkeyTaken(conflicts.first?.owner ?? "")
            } catch {
                return (error as? any LocalizedError)?.errorDescription ?? HostStrings.somethingWentWrong
            }
            self?.pop()
            self?.showHostToast(combo == nil ? HostStrings.hotkeyRemoved : HostStrings.hotkeySaved)
            return nil
        }
    }

    private func showHostToast(_ title: String) {
        showToast(.success(title), id: runtime.pipeline.makeToastID(), origin: nil)
    }
}
