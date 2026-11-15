import CoreBridge
import Kit

/// The calculator: answers arithmetic, percentages, units, currencies, dates and time zones in root
/// search as the user types, keeps the answers the user copies or pastes, and downloads exchange
/// rates from the European Central Bank once a day after the first currency conversion.
///
/// The engine is the Rust crate slick-calc through CoreBridge. One `Calculator` serves the feature;
/// its tables, zone rules and rate table are built off the main thread and attached.
public final class CalculatorFeature: Feature {
    nonisolated static let featureID = "calculator"

    public static let manifest = FeatureManifest(
        id: featureID, name: CalcStrings.featureName, icon: .symbol("plus.forwardslash.minus"),
        summary: CalcStrings.summary,
        permissions: [PermissionNeed(.accessibility, reason: CalcStrings.accessibilityReason)])

    let context: FeatureContext
    let engine: CalcEngine
    let rates: RateKeeper
    let history: CalcHistory
    let actionsMaker: CalcActions
    let provider: CalcProvider
    let historyList: HistoryList
    private let region: any RegionService
    private var startup: Task<Void, Never>?
    private var listeners: [Task<Void, Never>] = []

    /// Does no I/O. Services are chosen here and touch nothing until activation or a question.
    public init(context: FeatureContext) {
        self.context = context
        region = context.service(RegionServiceKey.self)
        let engine = CalcEngine(context: context, region: region)
        self.engine = engine
        rates = RateKeeper(context: context, service: context.service(ExchangeRateServiceKey.self)) { table in
            engine.calculator?.setRates(table)
        }
        history = CalcHistory(context: context)
        actionsMaker = CalcActions(history: history, rates: rates, settings: context.settings)
        provider = CalcProvider(engine: engine, rates: rates, actions: actionsMaker, context: context)
        historyList = HistoryList(history: history, actions: actionsMaker, clock: context.clock)
    }

    public var commands: [Command] {
        [
            Command(
                id: "history", title: CalcStrings.historyCommand, icon: .symbol("clock.arrow.circlepath"),
                keywords: CalcStrings.historyKeywords
            ) { [historyList] _ in
                .push(historyList.page())
            }
        ]
    }

    public var liveProviders: [LiveProvider] {
        [.instant(provider)]
    }

    /// Settings reads the status again when this fires: when the history file turns out to come
    /// from a newer version, or stops doing so.
    public var declarationChanges: ChangeSignal? { history.statusChanges }

    /// Says so in settings when the Rust core could not load, which only a broken build causes, or
    /// when the history file came from a newer version and is left as it is.
    public var status: FeatureStatus? {
        if engine.calculator == nil {
            return FeatureStatus(.failure, CalcStrings.engineMissingTitle, message: CalcStrings.engineMissingMessage)
        }
        if history.isReadOnly {
            return FeatureStatus(.warning, CalcStrings.readOnlyTitle, message: CalcStrings.readOnlyMessage)
        }
        return nil
    }

    public var settingsPane: SettingsPane? {
        CalcSettingsPane.pane(history: history)
    }

    /// Returns at once. Prepares the engine, reads the saved rates and history off the main thread,
    /// and follows settings and region changes. Nothing is downloaded and nothing prompts.
    public func activate() async {
        stopListening()
        // Subscribe before any work starts, so no change is missed.
        let settingChanges = context.settings.changes(
            ofAny: CalcSettings.contextKeys + [
                CalcSettings.historyLimit.erased, CalcSettings.downloadsRates.erased,
            ])
        let regionChanges = region.changes()
        let engine = self.engine
        let rates = self.rates
        let history = self.history
        history.reload()
        startup = Task {
            await engine.refresh()
            await rates.restoreSaved()
        }
        let contextNames = Set(CalcSettings.contextKeys.map(\.name))
        listeners.append(
            Task {
                for await name in settingChanges {
                    if contextNames.contains(name) {
                        await engine.refresh()
                    } else if name == CalcSettings.historyLimit.name {
                        await history.applyLimit()
                    } else if name == CalcSettings.downloadsRates.name, !rates.isEnabled {
                        rates.cancel()
                    }
                }
            })
        listeners.append(
            Task {
                for await _ in regionChanges {
                    await engine.refresh()
                }
            })
    }

    public func deactivate() async {
        stopListening()
        rates.cancel()
    }

    /// Waits until the engine can answer and the saved rates are attached, for tests and
    /// benchmarks.
    func waitUntilReady() async {
        await startup?.value
        await history.loaded()
    }

    private func stopListening() {
        startup?.cancel()
        for listener in listeners {
            listener.cancel()
        }
        listeners = []
    }
}
