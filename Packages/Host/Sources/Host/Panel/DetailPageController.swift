import AppKit
import Kit
import LauncherUI

/// A detail page: one ``Detail`` that a ``DetailSource`` streams in, such as an answer or a
/// script's output.
///
/// Updates apply to the page's ``detail`` as they arrive, with ``Detail/apply(_:)`` as the harness
/// does, and draw at most once per display frame: appended text goes to the pane as one append,
/// anything else redraws the detail. The page asks ``DetailSource/actions(for:)`` when it opens,
/// when a stream ends and when ``DetailSource/actionsChanged`` fires. With a
/// ``DetailSource/followUp``, Return on typed text cancels a running stream, clears the field and
/// applies the follow-up's stream on top. Popping the page cancels its streams; reload starts
/// again. While the panel is hidden a running stream keeps applying updates but nothing draws, and
/// an actions change or a reload waits: the page draws, asks and reloads once when shown.
@MainActor public final class DetailPageController: PageController {
    /// The longest an update waits before it is drawn: one frame at 120 Hz.
    public static let frameInterval: Duration = .microseconds(8_333)

    public let page: DetailPage
    public let origin: RunOrigin
    public let contentView = PageContentView()
    public let pane = DetailPane()

    /// What the page shows, with every update applied.
    public private(set) var detail = Detail()
    /// The actions from the last ask.
    public private(set) var actions: [Action] = []
    /// How often the page asked for actions, for tests.
    public private(set) var actionRequests = 0
    /// Draws so far, for tests: one per frame with updates, however many arrived.
    public private(set) var draws = 0
    /// Streams started: the first, reloads and follow-ups.
    public private(set) var streamsStarted = 0
    /// True while a stream runs.
    public var isStreaming: Bool { streamTask != nil }
    public var isBusy: Bool { streamTask != nil || flushTask != nil }
    public private(set) var query = ""

    private weak var host: (any PageHost)?
    private let presenter: DetailPresenter
    private var hasStarted = false
    private var streamTask: Task<Void, Never>?
    private var streamGeneration = 0
    private var flushTask: Task<Void, Never>?
    private var pendingAppend = ""
    private var needsFullDraw = false
    private var actionsWatcher: Task<Void, Never>?
    /// True while the panel is hidden with this page on top.
    public private(set) var isPanelHidden = false
    /// The actions changed, or a stream ended, while the panel was hidden.
    private var actionsStale = false
    /// A reload was asked for while the panel was hidden.
    private var reloadWhenShown = false

    public init(page: DetailPage, origin: RunOrigin) {
        self.page = page
        self.origin = origin
        presenter = DetailPresenter(pane: pane)
        contentView.show(pane)
        pane.onOpenLink = { [weak self] url in self?.open(url) }
    }

    /// The page's own title, or the title of the command that pushed it.
    public var title: String? { page.title ?? origin.commandTitle }
    public var featureID: String? { origin.featureID }
    public var searchPlaceholder: String { page.source.followUp?.placeholder ?? "" }

    // MARK: Lifecycle

    public func pageDidAppear(in host: any PageHost) {
        self.host = host
        presenter.rowMapper = host.rowMapper
        watchActions()
        guard !hasStarted else { return }
        hasStarted = true
        askForActions()
        start(page.source.start())
    }

    public func pageDidDisappear() {}

    public func iconsDidChange() {
        presenter.iconsDidChange()
    }

    public func panelDidHide() {
        isPanelHidden = true
        flushTask?.cancel()
        flushTask = nil
    }

    public func panelDidShow() {
        guard isPanelHidden else { return }
        isPanelHidden = false
        if reloadWhenShown {
            reloadWhenShown = false
            actionsStale = false
            reload()
            return
        }
        flush()
        if actionsStale {
            actionsStale = false
            askForActions()
        }
    }

    public func pageWillClose() {
        streamTask?.cancel()
        streamTask = nil
        flushTask?.cancel()
        flushTask = nil
        actionsWatcher?.cancel()
        actionsWatcher = nil
        presenter.cancel()
    }

    // MARK: Input

    public func queryDidChange(_ text: String) {
        query = text
    }

    public func moveSelection(_ move: SelectionMove) -> Bool { false }

    public func handle(_ command: QueryCommand) -> Bool {
        guard case .submit(let modifiers) = command, modifiers.isEmpty, page.source.followUp != nil else {
            return false
        }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        followUp(text)
        return true
    }

    /// Sends follow-up text: cancels a running stream, clears the field and applies the answer on
    /// top of what is shown.
    public func followUp(_ text: String) {
        streamTask?.cancel()
        streamTask = nil
        query = ""
        host?.replaceQueryText("")
        start(page.source.followUp(text))
    }

    public func reload() {
        guard !isPanelHidden else {
            reloadWhenShown = true
            return
        }
        streamTask?.cancel()
        streamTask = nil
        detail = Detail()
        needsFullDraw = true
        pendingAppend = ""
        flush()
        askForActions()
        start(page.source.start())
    }

    public var target: ActionTarget? {
        guard let runtime = host?.runtime else { return nil }
        let entries = runtime.visible(actions).map {
            ActionEntry($0, featureID: origin.featureID, context: origin.feature)
        }
        guard !entries.isEmpty else { return nil }
        return ActionTarget(
            row: nil, entries: entries, featureID: origin.featureID, context: origin.feature, launch: .page,
            query: query)
    }

    // MARK: Streaming

    private func start(_ stream: AsyncThrowingStream<DetailUpdate, any Error>) {
        streamGeneration += 1
        streamsStarted += 1
        let current = streamGeneration
        host?.page(self, isLoading: true)
        streamTask = Task { [weak self] in
            do {
                for try await update in stream {
                    guard let self, current == streamGeneration else { return }
                    receive(update)
                }
                self?.streamEnded(generation: current, error: nil)
            } catch {
                self?.streamEnded(generation: current, error: error)
            }
        }
    }

    private func streamEnded(generation current: Int, error: (any Error)?) {
        guard current == streamGeneration else { return }
        streamTask = nil
        if !isPanelHidden { flush() }
        host?.page(self, isLoading: false)
        if let error, !(error is CancellationError) { host?.pageDidFail(self, error: error) }
        guard !isPanelHidden else {
            actionsStale = true
            return
        }
        askForActions()
    }

    /// Applies one update to ``detail`` and schedules a draw for the next frame.
    private func receive(_ update: DetailUpdate) {
        let appendsToText: Bool
        switch detail.body {
        case .markdown, .text: appendsToText = true
        default: appendsToText = false
        }
        detail.apply(update)
        if case .append(let text) = update, appendsToText, !needsFullDraw {
            pendingAppend += text
        } else {
            needsFullDraw = true
            pendingAppend = ""
        }
        guard flushTask == nil, !isPanelHidden else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.frameInterval)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Draws what arrived since the last draw: one append, or the whole detail.
    private func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard needsFullDraw || !pendingAppend.isEmpty else { return }
        let meter = host?.workMeter
        if needsFullDraw {
            let detail = detail
            if let meter { meter.measure { presenter.show(detail) } } else { presenter.show(detail) }
        } else {
            var plainText = false
            if case .text = detail.body { plainText = true }
            let text = pendingAppend
            if let meter {
                meter.measure { presenter.append(text, plainText: plainText) }
            } else {
                presenter.append(text, plainText: plainText)
            }
        }
        needsFullDraw = false
        pendingAppend = ""
        draws += 1
    }

    /// Draws pending updates now, for benches and tests that cannot wait a frame.
    public func drawPendingUpdates() {
        flush()
    }

    /// Applies one update now, as if a stream had sent it, and draws it at once. For benches.
    public func applyNow(_ update: DetailUpdate) {
        receive(update)
        flush()
    }

    // MARK: Actions

    private func askForActions() {
        actions = page.source.actions(for: detail)
        actionRequests += 1
        host?.pageSelectionDidChange(self)
    }

    private func watchActions() {
        guard actionsWatcher == nil, let signal = page.source.actionsChanged else { return }
        let stream = signal.stream()
        actionsWatcher = Task { [weak self] in
            for await _ in stream { self?.actionsDidChange() }
        }
    }

    private func actionsDidChange() {
        if isPanelHidden {
            actionsStale = true
        } else {
            askForActions()
        }
    }

    private func open(_ url: URL) {
        let workspace = origin.feature.workspace
        Task { try? await workspace.open(url) }
    }
}
