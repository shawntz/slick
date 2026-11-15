import AppKit
import Kit
import KitHosting
import LauncherUI

/// The keyboard model from docs/ARCHITECTURE.md. Tests drive the same entry points the keys reach:
/// ``queryField(_:didChangeText:)`` and ``queryField(_:perform:)``.
extension PanelController: QueryFieldDelegate {
    public func queryField(_ field: QueryField, didChangeText text: String) {
        probe.begin(.keystroke, eventTimestamp: Self.currentEventTimestamp())
        top.queryDidChange(text)
        probe.markApplied()
    }

    public func queryField(_ field: QueryField, perform command: QueryCommand) -> Bool {
        if top.handle(command) { return true }
        switch command {
        case .moveUp: return move(.up)
        case .moveDown: return move(.down)
        case .moveToPreviousSection: return move(.previousSection)
        case .moveToNextSection: return move(.nextSection)
        case .moveLeft, .moveRight: return false
        case .submit(let modifiers):
            submit(modifiers: modifiers)
            return true
        case .cancel(let modifiers):
            if modifiers.contains(.command) {
                popToRoot()
            } else {
                escape()
            }
            return true
        case .complete: return complete()
        case .completeBackward: return false
        case .deleteOnEmpty:
            guard stack.count > 1 else { return false }
            pop()
            return true
        case .back:
            pop()
            return true
        case .chord(let chord): return handle(chord)
        }
    }

    public func queryField(_ field: QueryField, didChooseFilter option: MenuOption) {
        top.filterDidChange(option.id)
    }

    // MARK: Keys

    private func move(_ move: SelectionMove) -> Bool {
        probe.begin(.selection, eventTimestamp: Self.currentEventTimestamp())
        _ = top.moveSelection(move)
        probe.markApplied()
        // Always claimed: unclaimed, the field would move the caret instead.
        return true
    }

    /// Return runs the primary entry, Command-Return the secondary, and Return with other
    /// modifiers the entry whose shortcut is Return with those modifiers.
    func submit(modifiers: KeyChord.Modifiers) {
        guard let target = top.target else { return }
        let entry: ActionEntry?
        if modifiers.isEmpty {
            entry = target.primary
        } else if let match = target.entries.first(where: {
            $0.shortcut == KeyCombo(.return, Self.keyModifiers(modifiers))
        }) {
            entry = match
        } else {
            entry = modifiers == .command ? target.secondary : nil
        }
        guard let entry else { return }
        run(entry, target: target)
    }

    /// Escape clears the query, then goes back, then dismisses.
    func escape() {
        if !top.query.isEmpty {
            setQueryText("")
        } else if stack.count > 1 {
            pop()
        } else {
            dismiss()
        }
    }

    /// Tab at root: the selected row's completion, then the ghost completion, then the Tab command
    /// Root put in the snapshot with the typed text. Root checks that the command is on and takes
    /// the root query.
    private func complete() -> Bool {
        guard top === rootPage else { return false }
        if let completion = rootPage.selectedRow?.row.completion {
            setQueryText(completion)
        } else if let completion = rootPage.snapshot.completion, !rootPage.ghostText.isEmpty {
            setQueryText(completion.text)
        } else if !rootPage.query.isEmpty, let id = rootPage.snapshot.tabCommand {
            runtime.pipeline.runCommand(id, typedText: rootPage.query, launch: .tabFromRoot)
        }
        return true
    }

    private func handle(_ chord: KeyChord) -> Bool {
        // While a card shows, only Command-K, which closes the action panel, is the host's. Other
        // chords reach the card's own field and the Edit menu.
        if let overlay = surface.overlay {
            guard chord == KeyChord("k", .command), overlay === actionCard else { return false }
            surface.dismissOverlay()
            return true
        }
        if runShortcut(chord) { return true }
        guard chord.modifiers == .command else { return false }
        switch chord.key {
        case "k":
            openActionPanel()
            return true
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            runRow(at: Int(chord.key).map { $0 - 1 } ?? 0)
            return true
        case "p":
            guard top.filter != nil else { return false }
            surface.queryField.openFilterMenu()
            return true
        case "y":
            guard let url = top.target?.row?.quickLookURL else { return false }
            quickLook([url])
            return true
        case ",":
            onOpenSettings?()
            return onOpenSettings != nil
        default:
            return false
        }
    }

    /// Runs the selected row's entry whose shortcut is this chord, without opening the panel.
    private func runShortcut(_ chord: KeyChord) -> Bool {
        guard let combo = Self.keyCombo(chord), let target = top.target,
            let entry = target.entries.first(where: { $0.shortcut == combo })
        else { return false }
        run(entry, target: target)
        return true
    }

    /// Command-1 to 9: runs the Nth row's primary entry.
    func runRow(at index: Int) {
        guard let target = top.target(at: index), let entry = target.primary else { return }
        run(entry, target: target)
    }

    /// Replaces the search text as typing would, inside one keystroke interval.
    func setQueryText(_ text: String) {
        surface.queryField.text = text
        probe.begin(.keystroke)
        top.queryDidChange(text)
        probe.markApplied()
    }

    // MARK: Running

    /// Runs an entry from a target: through the pipeline, or the host's own handling for its
    /// entries and submenus. A root row is reported to Root first, before any `end()`.
    func run(_ entry: ActionEntry, target: ActionTarget) {
        let query = entry.query ?? target.query
        switch entry.kind {
        case .command(let command):
            runCommand(command, target: target)
        case .action(let action, let featureID, let context):
            if case .submenu = action.kind {
                openSubmenu(action, featureID: featureID, context: context, target: target, query: query)
                return
            }
            noteRootRun(target)
            runtime.pipeline.perform(
                action, featureID: featureID, context: context, query: query, launch: target.launch, row: target.row,
                arguments: CommandArguments(typedArguments(for: target)))
        case .host(let hostEntry):
            perform(hostEntry, target: target)
        case .toast(let action, let origin):
            runtime.pipeline.perform(action, origin: origin)
        case .custom(let body):
            body()
        }
    }

    private func runCommand(_ command: CommandEntry, target: ActionTarget) {
        if target.launch == .fallback {
            noteRootRun(target)
            runtime.pipeline.runCommand(command.id, typedText: target.query, launch: .fallback)
            return
        }
        let arguments = typedArguments(for: target)
        if chipsCommand == command.id, target.row?.id == command.id,
            let missing = command.command.arguments.firstIndex(where: {
                !$0.isOptional && $0.defaultValue == nil && (arguments[$0.name] ?? "").isEmpty
            })
        {
            surface.queryField.focusArgument(missing)
            return
        }
        // The page that asked for the arguments has done its work: the run's outcome lands below it.
        if let page = top as? ArgumentsPageController, page.command.id == command.id { pop() }
        noteRootRun(target)
        runtime.pipeline.runCommand(
            command.id, arguments: arguments, query: target.query, launch: target.launch, row: target.row)
    }

    /// The target's own argument values, then what the argument chips hold while they show the
    /// target row's command, so the command and its row actions get what the user typed. Empty
    /// chips leave a value out; the pipeline fills in defaults.
    func typedArguments(for target: ActionTarget) -> [String: String] {
        var values = target.arguments
        guard let id = target.row?.id, id == chipsCommand, let command = runtime.command(id) else { return values }
        let typed = surface.queryField.argumentValues
        for (index, argument) in command.command.arguments.enumerated() {
            let value = index < typed.count ? typed[index] : ""
            values[argument.name] = value.isEmpty ? nil : value
        }
        return values
    }

    private func noteRootRun(_ target: ActionTarget) {
        guard target.isRoot, let row = target.row else { return }
        rootSource.didRun(row, launch: target.launch)
    }

    // MARK: Conversions

    nonisolated static func keyModifiers(_ modifiers: KeyChord.Modifiers) -> KeyModifiers {
        var result: KeyModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }

    /// A LauncherUI chord as a Kit key combination, or nil for a key Kit cannot name.
    nonisolated static func keyCombo(_ chord: KeyChord) -> KeyCombo? {
        guard let key = Key(name: chord.key) else { return nil }
        return KeyCombo(key, keyModifiers(chord.modifiers))
    }

    /// The current key event's own time, when the current event is a key event.
    static func currentEventTimestamp() -> TimeInterval? {
        guard let event = NSApp?.currentEvent, event.type == .keyDown else { return nil }
        return event.timestamp
    }
}
