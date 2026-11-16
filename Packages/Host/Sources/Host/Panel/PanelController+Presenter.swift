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

    /// How long a destructive question in a session a link opened shows before its button works.
    /// The same wait as the page that asks before a link runs a command.
    public static let linkConfirmationHold: Duration = .seconds(1)

    /// The confirm card with a "Don't ask again" box when `suppressionKey` is set. Going ahead with
    /// the box checked stops the question for good, until settings asks it again.
    ///
    /// In a panel session a link opened, a destructive question starts on Cancel, so Return cancels
    /// until Tab moves to the confirm button, and it holds that button for ``linkConfirmationHold``
    /// on the services clock: a press or a click before then keeps the card and says to wait.
    public func confirm(_ confirmation: Confirmation, isDestructive: Bool, suppressionKey: String?) async -> Bool {
        let destructive = isDestructive || confirmation.isDestructive
        var content = ConfirmContent(
            title: confirmation.title, message: confirmation.message, confirmTitle: confirmation.confirmTitle,
            cancelTitle: HostStrings.cancel, isDestructive: destructive)
        if suppressionKey != nil { content.suppressionTitle = HostStrings.dontAskAgain }
        let holds = destructive && isPanelVisible && isLinkSession(sessionID)
        content.startsOnCancel = holds
        var checked = false
        let confirmed = await ask(content, holdsConfirm: holds) { card in checked = card.isSuppressionChecked }
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
    private func ask(
        _ content: ConfirmContent, holdsConfirm: Bool = false, onConfirm: ((ConfirmCardView) -> Void)? = nil
    ) async -> Bool {
        let opensPanel = !isPanelVisible
        if opensPanel { summon() }
        let session = sessionID
        let page = top
        pendingAnswer?.answer(false)
        let hold =
            holdsConfirm ? runtime.services.clock.now.addingTimeInterval(Self.seconds(Self.linkConfirmationHold)) : nil
        let answer = await present(content, holdUntil: hold, onConfirm: onConfirm)
        if opensPanel, !answer, pendingAnswer == nil, surface.overlay == nil, isPanelVisible, sessionID == session,
            top === page
        {
            dismiss()
        }
        return answer
    }

    /// Shows the card and waits for its answer. Before `holdUntil` on the services clock, the
    /// confirm button does not answer: the card shows again and a toast says to wait. When the
    /// asking run is cancelled, as when its feature is switched off, the card goes and the answer
    /// is no.
    private func present(
        _ content: ConfirmContent, holdUntil: Date?, onConfirm: ((ConfirmCardView) -> Void)?
    ) async -> Bool {
        let asked = AskedCard()
        return await withTaskCancellationHandler {
            await present(content, holdUntil: holdUntil, onConfirm: onConfirm, asked: asked)
        } onCancel: {
            Task { @MainActor [weak self] in self?.withdraw(asked.pending) }
        }
    }

    /// Takes down a card whose run was cancelled and answers it no. A card already answered or
    /// replaced is left alone.
    private func withdraw(_ pending: PendingAnswer?) {
        guard let pending else { return }
        pending.answer(false)
        guard pendingAnswer === pending else { return }
        pendingAnswer = nil
        if let card = pending.card, surface.overlay === card { surface.dismissOverlay() }
    }

    private func present(
        _ content: ConfirmContent, holdUntil: Date?, onConfirm: ((ConfirmCardView) -> Void)?, asked: AskedCard
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let pending = PendingAnswer(continuation)
            asked.pending = pending
            let card = ConfirmCardView(content: content)
            card.onConfirm = { [weak self, weak card, pending] in
                if let self, let holdUntil, runtime.services.clock.now < holdUntil {
                    // The card took itself down: put it back, still waiting for the same answer.
                    if let card, pendingAnswer === pending, surface.overlay == nil { surface.present(card) }
                    showToast(
                        .failure(
                            HostStrings.waitAMoment, message: HostStrings.waitBeforeConfirming(content.confirmTitle)),
                        id: runtime.pipeline.makeToastID(), origin: nil)
                    return
                }
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

    nonisolated static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// The card waiting for an answer now, if any. For tests and captures.
    public var pendingCard: ConfirmCardView? { pendingAnswer?.card as? ConfirmCardView }

    public func apply(_ outcome: ActionOutcome, origin: RunOrigin) {
        // A run that started in a session that has ended does not move the panel the user moved
        // on from. A close still shows its HUD.
        if let session = origin.session, session != sessionID || !isPanelVisible {
            if case .close(let hud?) = outcome { self.hud.show(hud) }
            // Like a HUD, Large Type still shows, unless the user is in the panel again.
            if case .showLargeType(let text) = outcome, !isPanelVisible { showLargeType(text) }
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
        case .showLargeType(let text):
            showLargeType(text)
        case .showRoot(let query):
            popAll()
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

/// The answer a question waits for, so the handler that runs when the asking run is cancelled can
/// take its card down.
@MainActor final class AskedCard {
    weak var pending: PendingAnswer?
}
