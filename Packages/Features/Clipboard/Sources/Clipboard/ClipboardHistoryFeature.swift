import Foundation
import Kit
import os

/// Clipboard history: records what other apps copy, and lets the user search it and paste it back.
///
/// - A monitor follows ``PasteboardService/entries()`` while the feature is on and recording is not
///   paused, and records each entry off the main thread (`Recorder.swift`).
/// - A SQLite store with a full-text index keeps the history in the feature's data folder, with
///   images and thumbnails beside it (`HistoryStore.swift`).
/// - The Clipboard History page loads a page at a time and searches in the store
///   (`HistoryList.swift`); actions come from `HistoryActions.swift`.
/// - The history answers `{clipboard offset=N}` for other features, and root search offers to paste
///   what was just copied (`RecentCopyTrigger.swift`).
public final class ClipboardHistoryFeature: Feature {
    public static let manifest = FeatureManifest(
        id: "clipboard", name: Strings.featureName, icon: .symbol("doc.on.clipboard"), summary: Strings.summary,
        permissions: [
            PermissionNeed(.pasteboard, reason: Strings.Permissions.pasteboard),
            PermissionNeed(.accessibility, reason: Strings.Permissions.accessibility),
        ],
        // It keeps what the user copies, so it starts only by the user's choice.
        isEnabledByDefault: false)

    let context: FeatureContext
    let store: HistoryStore
    /// Sent after the history changed: a copy, a deletion, a pin, pruning.
    let changes = ChangeSignal()
    /// Sent when the commands or the status change: recording paused or resumed, access granted.
    let declarations = ChangeSignal()
    let latest = LatestCopy()
    let recorder: Recorder

    private let builder: HistoryActions
    private let list: HistoryList
    private let trigger: RecentCopyTrigger
    private let reader: HistoryReader

    private var monitor: Task<Void, Never>?
    private var watchers: [Task<Void, Never>] = []
    private var accessWatch: Task<Void, Never>?
    /// Counts access watches, so a watch that ends late never clears a newer one.
    private var accessWatchGeneration = 0
    private var isActive = false
    /// The prune started at activation, for tests.
    private(set) var startupPrune: Task<Void, Never>?

    /// Does no I/O. The store opens its database on first use, off the main thread.
    public init(context: FeatureContext) {
        self.context = context
        store = HistoryStore(folder: context.storage.dataDirectory)
        recorder = Recorder(
            store: store, settings: context.settings, clock: context.clock, changes: changes, latest: latest,
            log: context.log)
        builder = HistoryActions(store: store, changes: changes, context: context)
        list = HistoryList(store: store, changes: changes, actions: builder, context: context)
        trigger = RecentCopyTrigger(
            store: store, latest: latest, changes: changes, actions: builder, workspace: context.workspace)
        reader = HistoryReader(store: store)
        list.onAccessMissing = { [weak self] in self?.watchAccess() }
    }

    /// Starts the monitor unless recording is paused, watches the settings that change it, and
    /// prunes in the background. Returns at once.
    public func activate() async {
        isActive = true
        let pauses = context.settings.changes(of: ClipboardSettings.isPaused)
        let limits = context.settings.changes(ofAny: [
            ClipboardSettings.retention.erased, ClipboardSettings.maximumItems.erased,
            ClipboardSettings.imageStorageMegabytes.erased,
        ])
        let recorder = recorder
        watchers = [
            Task { [weak self] in
                for await isPaused in pauses { self?.applyPause(isPaused) }
            },
            Task {
                for await _ in limits { await recorder.prune() }
            },
        ]
        if !context.settings[ClipboardSettings.isPaused] { startMonitor() }
        watchAccess()
        startupPrune = Task { await recorder.prune() }
    }

    /// Stops the monitor and the watches. The history stays on disk.
    public func deactivate() async {
        isActive = false
        stopMonitor()
        for task in watchers { task.cancel() }
        watchers = []
        accessWatch?.cancel()
        accessWatch = nil
        startupPrune?.cancel()
        latest.clear()
    }

    /// True while the monitor follows the pasteboard.
    var isMonitoring: Bool { monitor != nil }

    /// True while the feature waits for Paste from Other Apps to be granted.
    var isWatchingAccess: Bool { accessWatch != nil }

    public var declarationChanges: ChangeSignal? { declarations }

    public var suggestionTriggers: [any SuggestionTrigger] { [trigger] }

    public var provides: [ProvidedService] { [.clipboardHistory(reader)] }

    public var status: FeatureStatus? {
        if !context.permissions.isGranted(.pasteboard) {
            return FeatureStatus(
                .warning, Strings.Status.needsAccess, message: Strings.Status.needsAccessMessage,
                requires: [.pasteboard])
        }
        if context.settings[ClipboardSettings.isPaused] {
            return FeatureStatus(.info, Strings.Status.paused, message: Strings.Status.pausedMessage)
        }
        return nil
    }

    // MARK: - Commands

    public var commands: [Command] {
        let isPaused = context.settings[ClipboardSettings.isPaused]
        return [
            Command(
                id: "history", title: Strings.Commands.history, icon: Self.manifest.icon,
                keywords: Strings.Commands.historyKeywords
            ) { [list] _ in
                .push(
                    .list(
                        ListPage(
                            list, searchPlaceholder: Strings.Commands.searchPlaceholder, filter: KindFilter.dropdown,
                            showsDetail: true)))
            },
            Command(
                id: "clear-history", title: Strings.Commands.clearHistory, icon: .symbol("trash"),
                keywords: Strings.Commands.clearHistoryKeywords, confirmation: Strings.Commands.clearHistoryConfirmation
            ) { _ in
                .close(hud: .success(Strings.Actions.deleted(try await self.clearHistory())))
            },
            Command(
                id: "clear-recent", title: Strings.Commands.clearRecent, icon: .symbol("clock.arrow.circlepath"),
                keywords: Strings.Commands.clearRecentKeywords,
                arguments: [
                    CommandArgument(
                        "period", placeholder: Strings.Commands.periodPlaceholder,
                        kind: .dropdown(
                            RecentPeriod.allCases.map { .init(Strings.Period.title(for: $0), value: $0.rawValue) }),
                        isOptional: true, defaultValue: RecentPeriod.fifteenMinutes.rawValue)
                ],
                confirmation: Strings.Commands.clearRecentConfirmation
            ) { context in
                let period = context.arguments["period"].flatMap(RecentPeriod.init(rawValue:)) ?? .fifteenMinutes
                return .close(hud: .success(Strings.Actions.deleted(try await self.clearRecent(period))))
            },
            Command(
                id: "toggle-recording",
                title: isPaused ? Strings.Commands.resumeRecording : Strings.Commands.pauseRecording,
                icon: .symbol(isPaused ? "record.circle" : "pause.circle"), keywords: Strings.Commands.toggleKeywords
            ) { context in
                let pausing = !context.settings[ClipboardSettings.isPaused]
                context.settings[ClipboardSettings.isPaused] = pausing
                return .close(hud: HUD(pausing ? Strings.Commands.paused : Strings.Commands.resumed))
            },
        ]
    }

    // MARK: - Settings

    public var settingsPane: SettingsPane? {
        let locale = context.clock.locale
        return SettingsPane([
            SettingsSection(
                Strings.Settings.recordingSection,
                items: [
                    .toggle(Strings.Settings.pause, key: ClipboardSettings.isPaused, info: Strings.Settings.pauseInfo),
                    .permission(.pasteboard, info: Strings.Settings.accessInfo),
                ]),
            SettingsSection(
                Strings.Settings.historySection,
                items: [
                    // A choice that keeps less deletes items at once, so it asks first.
                    .picker(
                        Strings.Settings.retention, key: ClipboardSettings.retention,
                        info: Strings.Settings.retentionInfo, titles: Strings.Settings.retentionTitle
                    ) { stored, chosen in
                        chosen.keepsLess(than: stored) ? Strings.Settings.shortenRetention(to: chosen) : nil
                    },
                    .picker(
                        Strings.Settings.maximumItems, key: ClipboardSettings.maximumItems,
                        options: ClipboardSettings.maximumItemChoices.map {
                            ($0, Strings.Settings.itemsOption($0, locale: locale))
                        },
                        info: Strings.Settings.maximumItemsInfo
                    ) { stored, chosen in
                        chosen < stored ? Strings.Settings.lowerItemCap(to: chosen, locale: locale) : nil
                    },
                    .picker(
                        Strings.Settings.imageStorage, key: ClipboardSettings.imageStorageMegabytes,
                        options: ClipboardSettings.imageStorageChoices.map {
                            ($0, Strings.Settings.megabytes($0, locale: locale))
                        },
                        info: Strings.Settings.imageStorageInfo
                    ) { stored, chosen in
                        chosen < stored ? Strings.Settings.lowerImageSpace(to: chosen, locale: locale) : nil
                    },
                    .button(
                        Strings.Settings.clear, style: .destructive,
                        confirmation: Strings.Commands.clearHistoryConfirmation, info: Strings.Settings.clearInfo
                    ) { context in
                        context.showToast(.success(Strings.Actions.deleted(try await self.clearHistory())))
                    },
                ]),
            SettingsSection(
                Strings.Settings.pastingSection,
                items: [
                    .picker(
                        Strings.Settings.primaryAction, key: ClipboardSettings.primaryAction,
                        titles: Strings.Settings.primaryActionTitle),
                    .toggle(Strings.Settings.movesToTop, key: ClipboardSettings.movesUsedItemsToTop),
                    .permission(.accessibility, info: Strings.Settings.accessibilityInfo),
                ]),
            SettingsSection(
                Strings.Settings.privacySection, footer: Strings.Settings.storage(folder: storageFolderForDisplay),
                items: [
                    .list(
                        Strings.Settings.ignoredApps, key: ClipboardSettings.ignoredApps, itemKind: .application,
                        info: Strings.Settings.ignoredAppsInfo)
                ]),
        ])
    }

    /// The data folder as the user reads it, with the home folder written as "~".
    var storageFolderForDisplay: String {
        let folder = context.storage.dataDirectory.path
        let home = context.storage.homeDirectory.path
        guard !home.isEmpty, folder.hasPrefix(home + "/") else { return folder }
        return "~" + folder.dropFirst(home.count)
    }

    // MARK: - Work

    /// Deletes every unpinned item. Returns how many went.
    func clearHistory() async throws -> Int {
        let removed = try await store.deleteAll(keepingPinned: true)
        changes.send()
        return removed
    }

    /// Deletes unpinned items copied in the period. Returns how many went.
    func clearRecent(_ period: RecentPeriod) async throws -> Int {
        let removed = try await store.delete(copiedSince: context.clock.now.addingTimeInterval(-period.seconds))
        changes.send()
        return removed
    }

    private func applyPause(_ isPaused: Bool) {
        if isPaused {
            stopMonitor()
            latest.clear()
        } else {
            startMonitor()
        }
        context.log.info("Clipboard recording \(isPaused ? "paused" : "resumed")")
        declarations.send()
        changes.send()
    }

    /// Follows the pasteboard. Subscribing makes the live service poll; stopping ends the stream, so
    /// it stops polling while recording is paused. The task is detached, so not even its start waits
    /// for the main thread.
    private func startMonitor() {
        guard monitor == nil else { return }
        let entries = context.pasteboard.entries()
        let recorder = recorder
        monitor = Task.detached(priority: .utility) { await recorder.run(entries) }
    }

    private func stopMonitor() {
        monitor?.cancel()
        monitor = nil
    }

    /// While Paste from Other Apps is missing, waits for the user to grant it, then tells settings and
    /// the open page. The live stream checks once a second, so it stays open only until the grant.
    /// Activation starts it, and so does the history page when it finds access taken away later.
    private func watchAccess() {
        guard isActive, accessWatch == nil, !context.permissions.isGranted(.pasteboard) else { return }
        let statuses = context.permissions.changes(of: .pasteboard)
        accessWatchGeneration += 1
        let generation = accessWatchGeneration
        declarations.send()
        accessWatch = Task { [weak self] in
            for await status in statuses {
                self?.declarations.send()
                self?.changes.send()
                // Ending by cancellation, not by leaving the loop, tells the stream it is done.
                if status.isGranted { withUnsafeCurrentTask { $0?.cancel() } }
            }
            if let self, self.accessWatchGeneration == generation { self.accessWatch = nil }
        }
    }
}
