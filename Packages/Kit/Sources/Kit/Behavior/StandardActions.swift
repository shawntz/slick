import Foundation

/// Ready-made actions with the usual titles, icons and shortcuts. Use them so the same action looks
/// and behaves the same in every feature. Each one returns a value you can still adjust, for example
/// `.copy(text).with(section: "Copy")` or `.paste(text).recordingUse()`.
extension Action {
    /// Opens a URL or a file in its default app, then closes the panel.
    public static func open(_ url: URL, title: String = "Open", icon: Icon? = nil, shortcut: KeyCombo? = nil) -> Action
    {
        open([url], title: title, icon: icon, shortcut: shortcut)
    }

    /// Opens URLs or files, each in its default app. The panel closes before the first opens, since
    /// the workspace call waits until an app that was not running finishes launching.
    public static func open(_ urls: [URL], title: String = "Open", icon: Icon? = nil, shortcut: KeyCombo? = nil)
        -> Action
    {
        Action(title, id: "open", icon: icon ?? .symbol("arrow.up.forward.app"), shortcut: shortcut) { context in
            context.dismiss()
            for url in urls { try await context.workspace.open(url) }
            return .close()
        }
    }

    /// A submenu of the apps that can open the URL or file, the default first.
    public static func openWith(_ url: URL, title: String = "Open With") -> Action {
        openWith([url], title: title)
    }

    /// A submenu of the apps that can open the first item; the chosen app opens them all.
    public static func openWith(_ urls: [URL], title: String = "Open With") -> Action {
        openWith(title: title) { _ in urls }
    }

    /// A submenu of the apps that can open what `resolving` returns when the user opens the submenu,
    /// for a link that is rendered only then, such as a quicklink with placeholders.
    public static func openWith(
        title: String = "Open With", resolving urls: @escaping @MainActor @Sendable (ActionContext) async -> [URL]
    ) -> Action {
        .submenu(title, id: "open-with", icon: .symbol("arrow.up.right.square"), shortcut: .openWith) { context in
            let targets = await urls(context)
            guard let first = targets.first else { return [] }
            return await context.workspace.applications(toOpen: first).map { app in
                Action(app.name, id: "open-with." + app.bundleID, icon: .app(bundleID: app.bundleID)) { context in
                    context.dismiss()
                    try await context.workspace.open(targets, withApplication: app.bundleID)
                    return .close()
                }
            }
        }
    }

    /// Selects the files in Finder, then closes the panel.
    public static func reveal(_ urls: [URL], title: String = "Show in Finder") -> Action {
        Action(title, id: "reveal", icon: .symbol("folder"), shortcut: .reveal) { context in
            await context.workspace.reveal(urls)
            return .close()
        }
    }

    /// Closes the panel and shows the text in very large letters across the screen. The host
    /// already offers this for a row or detail whose `represents` is text; use it for other text,
    /// such as one field of a contact.
    public static func showInLargeType(_ text: String, title: String = "Show in Large Type") -> Action {
        Action(title, id: "large-type", icon: .symbol("textformat.size"), shortcut: .largeType) { _ in
            .showLargeType(text)
        }
    }

    /// Copies text, then closes the panel with a HUD.
    public static func copy(
        _ text: String, title: String = "Copy to Clipboard", hud: String = "Copied to Clipboard",
        shortcut: KeyCombo? = nil
    ) -> Action {
        copy(.text(text), title: title, hud: hud, shortcut: shortcut)
    }

    /// Copies any pasteboard content, then closes the panel with a HUD.
    public static func copy(
        _ content: PasteboardContent, title: String = "Copy to Clipboard", hud: String = "Copied to Clipboard",
        shortcut: KeyCombo? = nil
    ) -> Action {
        copy(title: title, hud: hud, shortcut: shortcut) { _ in content }
    }

    /// Copies content made when the action runs, such as an entry read from a database, then closes
    /// the panel with a HUD. Throw ``ActionFailure`` when there is nothing to copy.
    public static func copy(
        title: String = "Copy to Clipboard", hud: String = "Copied to Clipboard", shortcut: KeyCombo? = nil,
        content: @escaping @MainActor @Sendable (ActionContext) async throws -> PasteboardContent
    ) -> Action {
        Action(title, id: "copy", icon: .symbol("doc.on.doc"), shortcut: shortcut) { context in
            await context.pasteboard.copy(try await content(context), options: [])
            return .close(hud: HUD(hud))
        }
    }

    /// Copies a file's path, then closes the panel with a HUD.
    public static func copyPath(_ url: URL, title: String = "Copy Path") -> Action {
        copyPath([url], title: title)
    }

    /// Copies file paths, one per line, then closes the panel with a HUD.
    public static func copyPath(_ urls: [URL], title: String = "Copy Path") -> Action {
        Action(title, id: "copy-path", icon: .symbol("doc.on.clipboard"), shortcut: .copyPath) { context in
            await context.pasteboard.copy(urls.map(\.path).joined(separator: "\n"))
            return .close(hud: urls.count == 1 ? "Copied Path" : "Copied Paths")
        }
    }

    /// Pastes text into the frontmost app. Needs Accessibility; the host asks for it when missing.
    public static func paste(_ text: String, title: String = "Paste", shortcut: KeyCombo? = nil) -> Action {
        paste(.text(text), title: title, shortcut: shortcut)
    }

    /// Pastes content into the frontmost app. Needs Accessibility; the host asks for it when missing.
    public static func paste(_ content: PasteboardContent, title: String = "Paste", shortcut: KeyCombo? = nil) -> Action
    {
        paste(title: title, shortcut: shortcut) { _ in content }
    }

    /// Pastes content made when the action runs, such as an entry read from a database. Needs
    /// Accessibility. Throw ``ActionFailure`` when there is nothing to paste.
    public static func paste(
        title: String = "Paste", shortcut: KeyCombo? = nil,
        content: @escaping @MainActor @Sendable (ActionContext) async throws -> PasteboardContent
    ) -> Action {
        pasteAction(title: title, shortcut: shortcut) { context in
            try await context.pasteboard.paste(try await content(context))
        }
    }

    /// Pastes text made when the action runs and leaves the insertion point where the expansion
    /// says, such as a snippet with `{cursor}`. Needs Accessibility.
    public static func paste(
        title: String = "Paste", shortcut: KeyCombo? = nil,
        expansion: @escaping @MainActor @Sendable (ActionContext) async throws -> Expansion
    ) -> Action {
        pasteAction(title: title, shortcut: shortcut) { context in
            try await context.pasteboard.paste(try await expansion(context))
        }
    }

    private static func pasteAction(
        title: String, shortcut: KeyCombo?, paste: @escaping @MainActor @Sendable (ActionContext) async throws -> Void
    ) -> Action {
        let icon = Icon.symbol("doc.on.clipboard")
        return Action(title, id: "paste", icon: icon, shortcut: shortcut, requires: [.accessibility]) { context in
            try await paste(context)
            return .close()
        }
    }

    /// Shows a Quick Look preview inside the panel.
    public static func quickLook(_ url: URL, title: String = "Quick Look") -> Action {
        quickLook([url], title: title)
    }

    /// Shows Quick Look previews of several files inside the panel.
    public static func quickLook(_ urls: [URL], title: String = "Quick Look") -> Action {
        Action(title, id: "quick-look", icon: .symbol("eye"), shortcut: .quickLook) { context in
            context.quickLook(urls)
            return .keepOpen
        }
    }

    /// Moves files to the Trash after a confirmation, then reloads the page. Root forgets the files,
    /// so they stop showing up as remembered rows. The question names one file through
    /// ``DisplayText/fileName(_:limit:)``, so a line break or a direction override in its name
    /// shows as it is stored and is never obeyed.
    public static func moveToTrash(_ urls: [URL], title: String = "Move to Trash") -> Action {
        let what = urls.count == 1 ? "“\(DisplayText.fileName(urls[0].lastPathComponent))”" : "\(urls.count) items"
        return Action(
            title, id: "move-to-trash", icon: .symbol("trash"), shortcut: .remove, style: .destructive,
            confirmation: Confirmation("Move \(what) to the Trash?", confirmTitle: "Move to Trash", isDestructive: true)
        ) { context in
            _ = try await context.workspace.moveToTrash(urls)
            if let row = context.row { context.usage.forget(row.id) }
            context.reload()
            context.showToast(.success("Moved to Trash"))
            return .keepOpen
        }
    }

    /// Opens the system share menu.
    public static func share(_ items: [ShareItem], title: String = "Share…") -> Action {
        Action(title, id: "share", icon: .symbol("square.and.arrow.up")) { context in
            context.share(items)
            return .keepOpen
        }
    }

    /// Pushes a page built when the action runs.
    public static func push(
        _ title: String, id: String? = nil, icon: Icon? = nil, shortcut: KeyCombo? = nil,
        page: @escaping @MainActor @Sendable () -> Page
    ) -> Action {
        Action(title, id: id, icon: icon, shortcut: shortcut) { _ in .push(page()) }
    }

    /// Runs a command, possibly another feature's, with argument values by name. The host hides the
    /// action while the command is unavailable.
    public static func runCommand(
        _ id: ItemID, title: String, icon: Icon? = nil, arguments: [String: String] = [:]
    ) -> Action {
        Action(title, id: "run." + id.rawValue, icon: icon, requiresCommand: id) { _ in
            .run(id, arguments: arguments)
        }
    }

    /// A copy of the action with another ID, for two actions from one factory on the same row.
    public func with(id: String) -> Action {
        var copy = self
        copy.id = id
        return copy
    }

    /// A copy of the action with another shortcut.
    public func with(shortcut: KeyCombo?) -> Action {
        var copy = self
        copy.shortcut = shortcut
        return copy
    }

    /// A copy of the action in another action-panel section.
    public func with(section: String?) -> Action {
        var copy = self
        copy.section = section
        return copy
    }

    /// A copy of the action with another title.
    public func with(title: String) -> Action {
        var copy = self
        copy.title = title
        return copy
    }
}
