import AppKit
import Kit
import KitHosting
import LauncherUI

/// What runs see of the panel: toasts, HUDs, cards and outcomes.
extension PanelController: RunPresenter {
    public func showToast(_ toast: Toast, id: ToastID, origin: RunOrigin?) {
        toasts.show(toast, id: id, origin: origin, panelVisible: isPanelVisible)
    }

    public func dismissToast(_ id: ToastID) {
        toasts.dismiss(id)
    }

    public func showHUD(_ hud: HUD) {
        self.hud.show(hud)
    }

    /// The confirm card, in the middle of the panel. Opens the panel first when it is closed.
    public func confirm(_ confirmation: Confirmation, isDestructive: Bool) async -> Bool {
        await confirm(confirmation, isDestructive: isDestructive, suppressionKey: nil)
    }

    /// The confirm card with a "Don't ask again" box when `suppressionKey` is set. Going ahead with
    /// the box checked stops the question for good, until settings asks it again.
    public func confirm(_ confirmation: Confirmation, isDestructive: Bool, suppressionKey: String?) async -> Bool {
        var content = ConfirmContent(
            title: confirmation.title, message: confirmation.message, confirmTitle: confirmation.confirmTitle,
            cancelTitle: HostStrings.cancel, isDestructive: isDestructive || confirmation.isDestructive)
        if suppressionKey != nil { content.suppressionTitle = HostStrings.dontAskAgain }
        var checked = false
        let confirmed = await ask(content) { card in checked = card.isSuppressionChecked }
        if confirmed, checked, let suppressionKey {
            runtime.preferences.setConfirmationSuppressed(true, key: suppressionKey)
        }
        return confirmed
    }

    /// The permission card: why the feature needs it, and a button that asks the system.
    public func askForPermission(_ permission: Permission, featureName: String, reason: String) async -> Bool {
        let content = ConfirmContent(
            title: HostStrings.permissionTitle(feature: featureName, permission: permission.displayName),
            message: reason.isEmpty ? nil : reason,
            confirmTitle: permission == .fullDiskAccess ? HostStrings.openSettings : HostStrings.grantAccess,
            cancelTitle: HostStrings.cancel)
        return await ask(content)
    }

    /// Presents a confirm card and waits for the answer. A newer card, or a dismissed panel,
    /// answers false. A card asked while the panel was closed, as for a hotkey, a link or a keyword
    /// typed in another app, opens the panel for the question; when the user cancels it and nothing
    /// else changed, the panel closes again.
    private func ask(_ content: ConfirmContent, onConfirm: ((ConfirmCardView) -> Void)? = nil) async -> Bool {
        let opensPanel = !isPanelVisible
        if opensPanel { summon() }
        let session = sessionID
        let page = top
        pendingAnswer?.answer(false)
        let answer = await present(content, onConfirm: onConfirm)
        if opensPanel, !answer, pendingAnswer == nil, surface.overlay == nil, isPanelVisible, sessionID == session,
            top === page
        {
            dismiss()
        }
        return answer
    }

    private func present(_ content: ConfirmContent, onConfirm: ((ConfirmCardView) -> Void)?) async -> Bool {
        await withCheckedContinuation { continuation in
            let pending = PendingAnswer(continuation)
            let card = ConfirmCardView(content: content)
            card.onConfirm = { [weak self, weak card, pending] in
                if let card { onConfirm?(card) }
                pending.answer(true)
                if self?.pendingAnswer === pending { self?.pendingAnswer = nil }
            }
            card.onCancel = { [weak self, pending] in
                pending.answer(false)
                if self?.pendingAnswer === pending { self?.pendingAnswer = nil }
            }
            pending.card = card
            pendingAnswer = pending
            surface.present(card)
        }
    }

    /// The card waiting for an answer now, if any. For tests and captures.
    public var pendingCard: ConfirmCardView? { pendingAnswer?.card as? ConfirmCardView }

    public func apply(_ outcome: ActionOutcome, origin: RunOrigin) {
        // A run that started in a session that has ended does not move the panel the user moved
        // on from. A close still shows its HUD.
        if let session = origin.session, session != sessionID || !isPanelVisible {
            if case .close(let hud?) = outcome { self.hud.show(hud) }
            return
        }
        switch outcome {
        case .close(let hud):
            dismiss()
            if let hud { self.hud.show(hud) }
        case .keepOpen, .run, .needsPermission:
            break
        case .push(let page):
            push(makePage(page, origin: origin))
            if !isPanelVisible { summon() }
            if origin.startedByLink { noteLinkSession() }
        case .replace(let page):
            replaceTop(with: makePage(page, origin: origin))
            if !isPanelVisible { summon() }
            if origin.startedByLink { noteLinkSession() }
        case .pop:
            pop()
        case .popToRoot:
            popToRoot()
        case .showRoot(let query):
            popToRoot()
            if !isPanelVisible { summon() }
            if origin.startedByLink { noteLinkSession() }
            setQueryText(query)
        }
    }

    public func reloadTopPage() {
        top.reload()
    }

    public func setQuery(_ text: String) {
        setQueryText(text)
    }

    /// Previews files inside the panel, on a page of their own.
    public func quickLook(_ urls: [URL]) {
        if let onQuickLook {
            onQuickLook(urls)
            return
        }
        guard !urls.isEmpty else { return }
        if surface.overlay != nil { surface.dismissOverlay() }
        push(QuickLookPageController(urls: urls, makePreview: makePreviewView))
        if !isPanelVisible { summon() }
    }

    /// The share menu: the share sheet's services as entries in the action card.
    public func share(_ items: [ShareItem]) {
        if let onShare {
            onShare(items)
            return
        }
        let options = shareSheet?.options(for: items) ?? []
        guard let sheet = shareSheet, !options.isEmpty else {
            runtime.pipeline.showFailure(title: HostStrings.sharingUnavailable, message: nil)
            return
        }
        if !isPanelVisible { summon() }
        let entries = options.map { option in
            ActionEntry(
                title: option.title, icon: option.symbolName.map { .symbol($0) }, section: HostStrings.share,
                kind: .custom { sheet.share(items, with: option) })
        }
        let target = ActionTarget(
            row: nil, entries: entries, featureID: HostSettings.namespace, context: runtime.hostContext,
            launch: .page, query: "")
        showActionCard(entries, target: target)
    }

    public func dismissPanel() {
        dismiss()
    }

    /// Pushes a page that asks for the command's arguments in the search field, over whatever shows,
    /// and opens the panel when it is closed.
    public func askForArguments(
        _ command: CommandEntry, values: [String: String], query: String, launch: LaunchSource
    ) -> Bool {
        if surface.overlay === actionCard { surface.dismissOverlay() }
        let row =
            rootSource.row(for: command.id)
            ?? ArgumentsPageController.row(for: command, featureName: runtime.feature(command.featureID)?.manifest.name)
        let page = ArgumentsPageController(
            command: command, row: row, values: values, query: query, launch: launch,
            context: runtime.context(for: command.featureID))
        if top is ArgumentsPageController { replaceTop(with: page) } else { push(page) }
        if !isPanelVisible { summon() }
        if launch == .deeplink { noteLinkSession() }
        return true
    }
}
