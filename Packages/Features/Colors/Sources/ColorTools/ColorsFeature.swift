import Kit

/// Colors for people who design and build: pick a color on screen, keep a history of colors with
/// pins and names, and convert colors typed in root search between hex, RGB, HSL, HSB, HWB, OKLCH,
/// SwiftUI, AppKit and a CSS variable, with WCAG contrast.
///
/// - Pick Color closes the panel and shows the system's color sampler through ``ColorSampler``. The
///   picked color is copied in the default format, kept in the history, and named in a HUD.
/// - Color History lists the colors, pinned first, with a detail pane of every format and the
///   contrast against white and black.
/// - Typing a color, `color` and a CSS name, or `contrast` and two colors answers at the top of
///   root search.
public final class ColorsFeature: Feature {
    nonisolated static let featureID = "colors"
    /// The namespace of every row the feature makes.
    nonisolated static let namespace = "colors"

    public static let manifest = FeatureManifest(
        id: featureID, name: ColorStrings.featureName, icon: .symbol("eyedropper"), summary: ColorStrings.summary,
        permissions: [PermissionNeed(.accessibility, reason: ColorStrings.accessibilityReason)])

    let context: FeatureContext
    let sampler: any ColorSampler
    let history: ColorHistory
    let actionsMaker: ColorActions
    let provider: ColorProvider
    let historyList: HistoryList
    private var listener: Task<Void, Never>?

    /// Does no I/O. The sampler touches nothing until Pick Color runs.
    public init(context: FeatureContext) {
        self.context = context
        sampler = context.service(ColorSamplerKey.self)
        history = ColorHistory(context: context)
        actionsMaker = ColorActions(history: history, settings: context.settings)
        provider = ColorProvider(actions: actionsMaker, settings: context.settings)
        historyList = HistoryList(history: history, actions: actionsMaker, context: context)
    }

    public var commands: [Command] {
        [
            Command(
                id: "pick", title: ColorStrings.pickCommand, icon: .symbol("eyedropper"),
                keywords: ColorStrings.pickKeywords, runPolicy: .dropWhileRunning, allowsDeepLinks: false
            ) { [weak self] context in
                guard let self else { return .close() }
                return try await self.pick(context)
            },
            Command(
                id: "history", title: ColorStrings.historyCommand, icon: .symbol("swatchpalette"),
                keywords: ColorStrings.historyKeywords
            ) { [historyList] _ in
                .push(historyList.page())
            },
        ]
    }

    public var liveProviders: [LiveProvider] {
        [.instant(provider)]
    }

    /// Settings reads the status again when this fires: when the history file turns out to come
    /// from a newer version, or stops doing so.
    public var declarationChanges: ChangeSignal? { history.statusChanges }

    /// Says so in settings when the history file came from a newer version and is left as it is.
    public var status: FeatureStatus? {
        history.isReadOnly
            ? FeatureStatus(.warning, ColorStrings.readOnlyTitle, message: ColorStrings.readOnlyMessage) : nil
    }

    public var settingsPane: SettingsPane? {
        ColorSettings.pane(history: history)
    }

    /// Returns at once. Reads the history file off the main thread and follows the history's size.
    /// Nothing prompts and nothing is read but the feature's own file.
    public func activate() async {
        listener?.cancel()
        // Subscribe before any work starts, so no change is missed.
        let limitChanges = context.settings.changes(of: ColorSettings.historyLimit)
        history.reload()
        let history = self.history
        listener = Task {
            for await _ in limitChanges {
                await history.applyLimit()
            }
        }
    }

    public func deactivate() async {
        listener?.cancel()
        listener = nil
    }

    /// Waits until the history file was read, so scenarios see it before their first step.
    public func waitUntilReady() async {
        await history.loaded()
    }

    /// Closes the panel, shows the sampler, then copies the picked color in the default format,
    /// keeps it in the history and says what was copied. Escape in the sampler changes nothing.
    private func pick(_ context: ActionContext) async throws -> ActionOutcome {
        // The command stays out of deep links, and the app refuses a link that names it. Should a
        // link reach it anyway, a web page still cannot show the sampler and change the clipboard.
        guard context.launch != .deeplink else { return .close() }
        context.dismiss()
        let picked: PickedColor?
        do {
            picked = try await sampler.sample()
        } catch {
            throw ActionFailure(ColorStrings.unreadableTitle, message: ColorStrings.unreadableMessage)
        }
        // The system's sampler ignores cancellation and stays until the user clicks. When the run
        // was cancelled meanwhile, as when the feature was turned off, the click changes nothing.
        try Task.checkCancellation()
        guard let picked else { return .close() }
        guard let color = picked.color else {
            throw ActionFailure(ColorStrings.unreadableTitle, message: ColorStrings.unreadableMessage)
        }
        let text = actionsMaker.formatter.string(color, as: actionsMaker.defaultFormat)
        await context.pasteboard.copy(text)
        await history.add(color, source: .picked)
        return .close(hud: HUD(ColorStrings.copied(text)))
    }
}
