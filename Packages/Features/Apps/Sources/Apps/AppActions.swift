import Foundation
import Kit

/// The actions of an app row, in root search and on the Running Applications page.
extension AppsFeature {
    /// Shortcuts that match what people know from other launchers, where Kit has no constant.
    /// Command-Return shows in Finder, as in Raycast; Kit's constants cover the rest.
    enum Shortcut {
        static let packageContents = KeyCombo(.i, [.option, .command])
        static let hide = KeyCombo(.h, [.shift, .command])
        static let quit = KeyCombo(.q, [.control, .shift])
        static let forceQuit = KeyCombo(.q, [.control, .option, .shift])
        static let restart = KeyCombo(.r, [.shift, .command])
        static let copyBundleID = KeyCombo(.c, [.option, .shift, .command])
    }

    /// The app a row stands for: from its payload, which survives a relaunch, or else from the scan.
    func reference(for row: Row) -> AppReference? {
        if let reference = try? row.payload?.decode(AppReference.self) { return reference }
        return installed.first { $0.key == row.id.key }?.reference
    }

    /// The running copies of an app, from what the feature already knows. No I/O.
    func instances(of app: AppReference) -> [RunningApp] {
        running.filter(app.matches)
    }

    /// Open first and Show in Finder second, so Return opens and Command-Return reveals. Hide, Quit,
    /// Restart and Force Quit show only while the app runs. Move to Trash never shows for an app on
    /// the system volume.
    func actions(forAppRow row: Row) -> [Action] {
        guard let app = reference(for: row) else { return [] }
        var actions: [Action] = [
            Action("Open", id: "open", icon: .symbol("arrow.up.forward.app")) { context in
                try await Self.open(app, context: context)
                return .close()
            },
            .reveal([app.url]).with(shortcut: .secondaryAction),
            .open(
                app.url.appending(path: "Contents", directoryHint: .isDirectory), title: "Show Package Contents",
                icon: .symbol("shippingbox"), shortcut: Shortcut.packageContents
            ).with(id: "show-package-contents"),
        ]
        if !instances(of: app).isEmpty {
            actions += runningActions(for: app)
        }
        actions.append(.copy(app.name, title: "Copy Name", hud: "Copied Name", shortcut: .copy).with(id: "copy-name"))
        if let bundleID = app.bundleID {
            let copy = Action.copy(
                bundleID, title: "Copy Bundle Identifier", hud: "Copied Bundle Identifier",
                shortcut: Shortcut.copyBundleID)
            actions.append(copy.with(id: "copy-bundle-id"))
        }
        actions.append(.copyPath(app.url))
        if !app.isSystem {
            // The file watcher notices too; rescanning at once updates root search sooner.
            actions.append(.moveToTrash([app.url]).then { _ in await self.rescan().value })
        }
        return actions
    }

    private func runningActions(for app: AppReference) -> [Action] {
        let section = "Running"
        let service = runningApps
        return [
            Action("Hide", id: "hide", icon: .symbol("eye.slash"), shortcut: Shortcut.hide, section: section) {
                context in
                try await self.forEachCopy(of: app, failure: "Could Not Hide \(app.name)") { await service.hide($0) }
                return Self.finish(context, "Hid \(app.name)")
            },
            Action("Quit", id: "quit", icon: .symbol("xmark.circle"), shortcut: Shortcut.quit, section: section) {
                context in
                try await self.forEachCopy(of: app, failure: "Could Not Quit \(app.name)") { await service.quit($0) }
                return Self.finish(context, "Quitting \(app.name)")
            },
            Action(
                "Restart", id: "restart", icon: .symbol("arrow.clockwise"), shortcut: Shortcut.restart,
                section: section
            ) { context in
                try await self.restart(app, context: context)
                return .close(hud: "Restarted \(app.name)")
            },
            Action(
                "Force Quit", id: "force-quit", icon: .symbol("xmark.octagon"), shortcut: Shortcut.forceQuit,
                style: .destructive, section: section,
                confirmation: Confirmation(
                    "Force Quit \(app.name)?", message: "Changes you have not saved in \(app.name) will be lost.",
                    confirmTitle: "Force Quit", isDestructive: true)
            ) { context in
                try await self.forEachCopy(of: app, failure: "Could Not Force Quit \(app.name)") {
                    await service.forceQuit($0)
                }
                return Self.finish(context, "Force Quit \(app.name)")
            },
        ]
    }

    /// Runs an operation on every running copy of the app, read when the action runs rather than
    /// when the panel opened. Throws when one fails, which the host shows as a failure toast.
    private func forEachCopy(
        of app: AppReference, failure: String, _ operation: (RunningApp) async -> Bool
    ) async throws {
        for instance in instances(of: app) {
            guard await operation(instance) else { throw ActionFailure(failure) }
        }
    }

    /// Quits every copy, waits up to 10 seconds for each to go, then opens the app again. The panel
    /// closes first, since an app with unsaved work may ask the user before it quits.
    private func restart(_ app: AppReference, context: ActionContext) async throws {
        context.dismiss()
        let copies = instances(of: app)
        for instance in copies {
            guard await runningApps.quit(instance) else { throw ActionFailure("Could Not Quit \(app.name)") }
        }
        for instance in copies {
            guard await runningApps.waitUntilQuit(instance, timeout: .seconds(10)) else {
                throw ActionFailure("\(app.name) Did Not Quit", message: "It may be waiting for you to save changes.")
            }
        }
        try await Self.open(app, context: context)
    }

    /// Opens or brings forward an app through Kit's workspace service. The first copy of an app opens
    /// by bundle ID, which brings a running copy forward; a second copy, or a bundle with no ID, opens
    /// by path.
    static func open(_ app: AppReference, context: ActionContext) async throws {
        if app.opensByBundleID, let bundleID = app.bundleID {
            try await context.workspace.launch(bundleID: bundleID)
        } else {
            try await context.workspace.open(app.url)
        }
    }

    /// From root search the panel closes with a HUD. On the Running Applications page it stays open
    /// with a toast, and the change signal updates the rows.
    static func finish(_ context: ActionContext, _ message: String) -> ActionOutcome {
        guard context.launch == .page else { return .close(hud: HUD(message)) }
        context.showToast(.success(message))
        return .keepOpen
    }
}
