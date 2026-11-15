import Foundation
import Kit

/// The panel closing and opening again, going back a page, and grants made in settings, as the host
/// reports them to a feature.
extension FeatureHarness {
    /// Closes the panel, as Escape or a click elsewhere does. Every page in the stack whose source
    /// adopts ``PageEvents`` hears ``PageEvents/panelDidClose()``, top first, and toasts show as HUDs
    /// until ``openPanel()``. An outcome that closes the panel and ``ActionContext/dismiss()`` do the
    /// same.
    public func closePanel() {
        guard !isClosed else { return }
        isClosed = true
        visibleToast = nil
        visibleToastID = nil
        tellPagesThePanelClosed()
    }

    /// Opens the panel again on the page that was on top, as the next summon does when the stack did
    /// not return to root search. The page's source hears
    /// ``PageEvents/pageWillShowAgain(_:)`` with ``PageShowReason/panelOpened``, then the page loads
    /// again when its source changed while it was hidden.
    public func openPanel() async throws {
        let wasClosed = isClosed
        isClosed = false
        guard wasClosed, let state = page else { return }
        pageEvents(of: state)?.pageWillShowAgain(.panelOpened)
        if isStale(state) { try await load(state, reason: .reload) }
    }

    /// Goes back one page, as the host does. Unlike ``pop()``, the page below hears
    /// ``PageEvents/pageWillShowAgain(_:)`` with ``PageShowReason/returned`` and loads again when
    /// its source changed while it was covered.
    public func goBack() async throws {
        guard !pages.isEmpty else { throw HarnessError.noPage }
        pages.removeLast()
        guard let state = page else { return }
        pageEvents(of: state)?.pageWillShowAgain(.returned)
        if isStale(state) { try await load(state, reason: .reload) }
    }

    /// Grants a permission as the user does with a Grant button in the settings window or in
    /// onboarding. The fake permission center then reports it granted, and, when the manifest lists
    /// it, the feature hears ``Feature/permissionGranted(_:)``, as the host tells it. Then the harness
    /// settles, so work the grant started is done and an open page that changed is loaded again.
    public func grantInSettings(_ permission: Permission) async throws {
        let wasGranted = fakes.permissions.status(of: permission).isGranted
        fakes.permissions.set(permission, to: .granted)
        if !wasGranted { await announceGrant(of: permission) }
        try await settle()
    }

    /// The page's source as a ``PageEvents``, when it adopts it.
    func pageEvents(of state: PageState) -> (any PageEvents)? {
        switch state.page {
        case .list(let list): list.source as? any PageEvents
        case .grid(let grid): grid.source as? any PageEvents
        case .detail(let detail): detail.source as? any PageEvents
        case .form: nil
        }
    }

    /// Tells every page in the stack, top first, that the panel closed.
    func tellPagesThePanelClosed() {
        for state in pages.reversed() {
            pageEvents(of: state)?.panelDidClose()
        }
    }

    /// Tells the feature that the user granted a permission its manifest lists, as the host does
    /// after a grant through settings, onboarding or the panel's permission card.
    func announceGrant(of permission: Permission) async {
        guard F.manifest.permissions.contains(where: { $0.permission == permission }) else { return }
        await feature.permissionGranted(permission)
    }
}
