import CoreBridge
import Foundation
import Kit
import KitHosting
import os

/// Root search: the ``RootSource`` the panel drives, and the two Kit services the engine backs.
///
/// App makes one at launch and keeps it for the life of the app:
///
/// ```swift
/// let root = RootSearch(RootConfiguration(directory: runtime, preferences: runtime, ...))
/// // root.usage and root.fuzzyIndex go into the features' Services; root is Host's RootSource.
/// ```
///
/// The initializer returns at once. The engine opens on its own queue and the catalog loads in the
/// background; until then a query finds only instant answers and fallbacks. ``status`` says where
/// learning goes, and ``statusChanges`` fires when it changes.
///
/// The synchronous path, ``begin()`` and ``update(query:)``, does no I/O, takes no lock that work
/// can hold for long, and never waits for the engine queue. Everything that changes the engine runs
/// on that queue in order: catalog rebuilds, learning, context and aliases.
public final class RootSearch: RootSource {
    /// The most engine results one query shows.
    nonisolated static let resultLimit = 50
    /// Rows whose title highlights ``update(query:)`` fills itself.
    nonisolated static let highlightedRows = 12
    /// Suggestions kept ready for the empty query, more than any count setting shows, so favorites
    /// can take some without leaving the section short.
    nonisolated static let suggestionDepth = 16

    public let changes = ChangeSignal()
    /// Fires when ``status`` changes.
    public let statusChanges = ChangeSignal()
    public private(set) var status: RootStatus = .opening
    public internal(set) var snapshot = RootSnapshot()

    /// Records uses for features and for root search. Give it to the features' services.
    public let usage: any UsageService
    /// Fuzzy indexes over the engine's matcher. Give it to the features' services.
    public let fuzzyIndex: any FuzzyIndexService
    /// This object as the panel's data source.
    public var source: any RootSource { self }

    /// Records where ``update(query:)`` spends its time. For the bench; nil in the app.
    @_spi(RootBench) public var timings: UpdateTimings?

    let configuration: RootConfiguration
    let hostSettings: FeatureSettings
    let worker = EngineWorker()
    let memory: ItemMemory
    let usageService: RootUsageService
    let log = KitLog.logger(category: "root")

    /// Set once the engine opened. Queries read it directly on the main thread.
    var engine: Engine?
    /// The session the engine narrows from keystroke to keystroke. Nil only when the engine's
    /// session could not be made.
    let buffer: QueryBuffer?
    var table = CatalogTable()
    var plan = DirectoryPlan()
    var slots: [ObjectIdentifier: SourceSlot] = [:]
    var slotOrder: [ObjectIdentifier] = []
    var fallbacks: [DirectoryPlan.FallbackEntry] = []
    var settingsCache: RootSettingsCache
    var appliedAliases: [ItemID: String] = [:]

    // MARK: Session

    var inSession = false
    var revision = 0
    /// Grows with every query, so late async results for an older query are dropped.
    var queryGeneration = 0
    /// The empty-query snapshot, prepared whenever what it shows changed.
    var preparedEmpty = RootSnapshot()
    /// The engine's suggestions for the current context, best first.
    var suggestionKeys: [UInt64] = []
    /// Keys of the current results that matched through a user alias. Reused across keystrokes.
    var aliasHitKeys: [UInt64] = []
    /// Keys of the current instant answers. Reused across keystrokes.
    var answerKeys: [UInt64] = []
    /// The async provider sections the current query waits for, in display order.
    var pendingProviders: [PendingProvider] = []
    /// One task per pending provider: its debounce, then its results. Cancelled when the query
    /// changes.
    var providerTasks: [Task<Void, Never>] = []
    /// Pending providers that have not delivered yet. The snapshot is loading while this is above 0.
    var providersOutstanding = 0
    /// One listener per instant provider that declares ``InstantProvider/answersChanged``.
    var answerListeners: [ObjectIdentifier: Task<Void, Never>] = [:]

    // MARK: Suggestion triggers

    var triggerSlots: [ObjectIdentifier: TriggerSlot] = [:]
    var triggerOrder: [ObjectIdentifier] = []
    /// The Thompson draw per trigger type, kept for one panel session.
    var triggerDraws: [String: Double] = [:]
    /// True after a session ended: the next prepared snapshot draws again.
    var drawsStale = true
    /// The trigger rows in the prepared empty snapshot.
    var preparedTriggers: [ShownTrigger] = []
    /// The trigger rows the running session showed, and the ones the user ran.
    var shownTriggers: [ShownTrigger] = []
    var acceptedTriggerRows: [ItemID] = []
    /// When the running session began, and when the user first typed in it.
    var sessionBeganAt: Date?
    var sessionTypedAt: Date?
    var suggestionTimer: Task<Void, Never>?
    /// The Thompson sampling generator. Fixed seed outside the live environment, so tests repeat.
    var random: SplitMix64

    // MARK: Live subtitles

    /// The last fetched subtitle of each command with a live subtitle, with its color.
    var subtitleValues: [ItemID: LiveSubtitle.Value] = [:]
    /// The refresh loops of the visible commands with a live subtitle.
    var subtitleRunners: [ItemID: [Task<Void, Never>]] = [:]
    /// True when the prepared empty snapshot shows a command with a live subtitle.
    var preparedHasLiveSubtitles = false

    // MARK: Learning and context

    var lastRun: ContextBuilder.LastRun?
    var sessionStart = false
    let learning: LearningStore
    /// Learning for the settings inspector. Give it to SettingsUI.
    public private(set) lazy var inspector: RootLearningInspector = RootLearningInspector(root: self)
    var seedingStarted = false

    // MARK: Background work

    var tasks: [Task<Void, Never>] = []
    var expiryTask: Task<Void, Never>?
    var inFlight = 0
    var idleWaiters: [CheckedContinuation<Void, Never>] = []
    var openWaiters: [CheckedContinuation<Void, Never>] = []
    var isOpen = false
    var rebuildRunning = false
    var rebuildAgain = false
    var isShutDown = false

    /// Starts root search. Returns at once; see ``ready()``.
    public init(_ configuration: RootConfiguration) {
        self.configuration = configuration
        hostSettings = HostSettings.settings(configuration.settings)
        memory = ItemMemory(
            usageFile: configuration.storage.usageFile, rememberedFile: configuration.storage.rememberedFile)
        usageService = RootUsageService(memory: memory, clock: configuration.clock)
        usage = usageService
        fuzzyIndex = EngineFuzzyIndexService()
        buffer = try? QueryBuffer(capacity: Self.resultLimit)
        settingsCache = RootSettingsCache(hostSettings)
        learning = LearningStore(file: configuration.storage.learningFile)
        if configuration.environment == .live {
            var system = SystemRandomNumberGenerator()
            random = SplitMix64(seed: system.next())
        } else {
            random = SplitMix64(seed: 0x5EED_0F_C0FFEE)
        }

        let engineDirectory = configuration.environment == .live ? configuration.storage.engineDirectory : nil
        beginWork()
        worker.open(directory: engineDirectory) { [weak self] engine, status in
            Task { @MainActor [weak self] in self?.engineOpened(engine, status: status) }
        }
        usageService.onRememberedRowRemoved { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleRebuild() }
        }
        beginWork()
        let memory = memory
        Task { [weak self] in
            await memory.load()
            self?.memoryLoaded()
        }
        beginWork()
        let learning = learning
        Task { [weak self] in
            await learning.load()
            self?.learningLoaded()
        }
        startListening()
        readDirectory()
        applyAliases()
        applyLearningPaused()
        refreshContext()
    }

    // MARK: Lifecycle

    /// Returns once the engine is open, the stored rows are loaded and every catalog source has
    /// loaded once. App does not need to wait; tests and the bench do.
    public func ready() async {
        if !isOpen {
            await withCheckedContinuation { openWaiters.append($0) }
        }
        await settle()
    }

    /// Returns once the background work started so far is done: source loads, catalog rebuilds,
    /// learning and context changes, and file writes. For tests and the bench.
    public func settle() async {
        var quietRounds = 0
        while quietRounds < 2 {
            for _ in 0..<10 { await Task.yield() }
            await worker.drain()
            await memory.drain()
            for _ in 0..<10 { await Task.yield() }
            if inFlight == 0 {
                quietRounds += 1
            } else {
                quietRounds = 0
                await withCheckedContinuation { idleWaiters.append($0) }
            }
        }
    }

    /// Writes everything learned and remembered so far. Call it at quit.
    public func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            worker.perform { engine in
                try? engine?.flush()
                continuation.resume()
            }
        }
        await memory.drain()
        await learning.drain()
    }

    /// Stops every background task, writes what is pending and lets the engine go, which frees its
    /// data folder. Root search answers nothing afterwards.
    public func shutdown() async {
        isShutDown = true
        for task in tasks { task.cancel() }
        tasks = []
        expiryTask?.cancel()
        expiryTask = nil
        suggestionTimer?.cancel()
        suggestionTimer = nil
        for slot in slots.values { slot.stop() }
        for slot in triggerSlots.values { slot.stop() }
        for listener in answerListeners.values { listener.cancel() }
        answerListeners = [:]
        cancelProviders()
        stopLiveSubtitles()
        engine = nil
        inSession = false
        await memory.drain()
        await learning.drain()
        await worker.close()
    }

    private func engineOpened(_ engine: Engine?, status: RootStatus) {
        self.engine = isShutDown ? nil : engine
        self.status = status
        isOpen = true
        statusChanges.send()
        if case .inMemory = status {
            log.warning("root search keeps learning in memory: \(String(describing: status), privacy: .public)")
        }
        let waiters = openWaiters
        openWaiters = []
        for waiter in waiters { waiter.resume() }
        seedIfFirstRun()
        endWork()
    }

    private func memoryLoaded() {
        if lastRun == nil, let last = memory.lastUse() {
            lastRun = ContextBuilder.LastRun(key: last.id.engineKey, at: last.at)
            refreshContext()
        }
        scheduleRebuild()
        validateRememberedRows()
        endWork()
    }

    private func learningLoaded() {
        seedIfFirstRun()
        prepareEmptySnapshot()
        endWork()
    }

    // MARK: Work tracking

    func beginWork() {
        inFlight += 1
    }

    func endWork() {
        inFlight -= 1
        guard inFlight == 0 else { return }
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}

/// Where ``RootSearch/update(query:)`` spent main-thread CPU time, for the bench.
@_spi(RootBench) public final class UpdateTimings {
    /// Main-thread CPU nanoseconds inside the engine query, one per typed query.
    public var engineNanos: [UInt64] = []
    /// Main-thread CPU nanoseconds to put one async provider's rows into the snapshot.
    public var deliveryNanos: [UInt64] = []

    public init(capacity: Int) {
        engineNanos.reserveCapacity(capacity)
        deliveryNanos.reserveCapacity(capacity)
    }
}

extension RootSearch {
    /// The engine, for the bench to measure the same query outside the mapping.
    @_spi(RootBench) public var benchEngine: Engine? { engine }

    /// Items in the catalog the main thread maps hits with.
    @_spi(RootBench) public var catalogCount: Int { table.count }
}
