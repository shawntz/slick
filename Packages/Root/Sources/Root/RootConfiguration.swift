import Foundation
import Kit
import KitHosting

/// Where root search keeps its files.
///
/// Inside ``directory``:
///
/// - `engine/`: the engine's event log and snapshot. Used only in the live environment.
/// - `remembered.json`: rows the user ran that came from live providers or suggestions.
/// - `usage.json`: what ``UsageService`` records.
/// - `learning.json`: first-run seeding, the first recorded run and what the triggers learned.
public struct RootStoragePaths: Hashable, Sendable {
    /// The folder name under the app's data folder when the paths come from a ``StorageService``.
    /// It contains a ".", which no feature ID may, so it never clashes with a feature's folder.
    public static let folderName = "app.root"

    /// Root search's own folder. Nil keeps everything in memory.
    public var directory: URL?

    public init(directory: URL?) {
        self.directory = directory
    }

    /// Root search's folder inside the app's data folder.
    public init(storage: any StorageService) {
        self.init(directory: storage.dataDirectory(for: Self.folderName))
    }

    /// Nothing is written.
    public static let inMemory = RootStoragePaths(directory: nil)

    var engineDirectory: URL? {
        directory?.appending(path: "engine", directoryHint: .isDirectory)
    }

    var rememberedFile: URL? {
        directory?.appending(path: "remembered.json", directoryHint: .notDirectory)
    }

    var usageFile: URL? {
        directory?.appending(path: "usage.json", directoryHint: .notDirectory)
    }

    var learningFile: URL? {
        directory?.appending(path: "learning.json", directoryHint: .notDirectory)
    }
}

/// Everything root search reads. App builds one and passes it to ``RootSearch/init(_:)``.
public struct RootConfiguration: Sendable {
    /// The registered features. It may still be empty: Root reads it again on every change.
    public var directory: any FeatureDirectory
    /// Aliases and favorites.
    public var preferences: any ItemPreferences
    /// The frontmost app, power, displays, audio route and Focus, for prediction.
    public var systemContext: any SystemContextService
    /// The settings service that holds ``HostSettings``.
    public var settings: any SettingsService
    public var clock: any ClockService
    /// Where root search keeps its files.
    public var storage: RootStoragePaths
    /// The engine saves learning only in ``RunEnvironment/live``. Elsewhere it runs in memory, while
    /// remembered rows and usage still go to ``storage`` when it has a folder.
    public var environment: RunEnvironment
    /// Catalog sources Root owns rather than a feature, such as the installed applications in the
    /// reserved `app` namespace. Their rows have no feature ID.
    public var builtInSources: [any CatalogSource]
    /// Light priors for the first run, such as the apps in the Dock. Root calls it once, off the main
    /// thread, when nothing was learned yet and no seeding ran before; never again after that. App
    /// gathers the items: Root reads no Dock, Spotlight or running-app list itself. Nil seeds nothing.
    public var firstRunSeeds: (@Sendable () async -> [LearningSeed])?

    public init(
        directory: any FeatureDirectory,
        preferences: any ItemPreferences,
        systemContext: any SystemContextService,
        settings: any SettingsService,
        clock: any ClockService,
        storage: RootStoragePaths,
        environment: RunEnvironment,
        builtInSources: [any CatalogSource] = [],
        firstRunSeeds: (@Sendable () async -> [LearningSeed])? = nil
    ) {
        self.directory = directory
        self.preferences = preferences
        self.systemContext = systemContext
        self.settings = settings
        self.clock = clock
        self.storage = storage
        self.environment = environment
        self.builtInSources = builtInSources
        self.firstRunSeeds = firstRunSeeds
    }
}

/// One light prior for the first run: an item the user probably uses, how much, and when last.
///
/// A seed counts like a fraction of a use in the zero-query prediction and in typed frecency only,
/// never in query affinity or the context tables, and it fades within about two weeks. Seeds must be
/// light: weighted like real uses they make the first suggestions worse. The factories below hold
/// the weights the prediction research settled on; App picks the factory for what it found.
nonisolated public struct LearningSeed: Hashable, Sendable {
    /// The heaviest weight one item gets, after its seeds are added up.
    public static let maximumWeight = 1.0

    /// The item, such as `app:<bundle id>`.
    public var id: ItemID
    /// The fraction of a use, above 0 and at most ``maximumWeight``.
    public var weight: Double
    /// When the use counts as made.
    public var lastUsed: Date

    public init(id: ItemID, weight: Double, lastUsed: Date) {
        self.id = id
        self.weight = weight
        self.lastUsed = lastUsed
    }

    /// An app with a use count from Spotlight: 0.15 times the natural log of one plus the count, at
    /// its last use.
    public static func countedApp(_ id: ItemID, useCount: Int, lastUsed: Date) -> LearningSeed {
        LearningSeed(id: id, weight: 0.15 * log1p(Double(max(useCount, 0))), lastUsed: lastUsed)
    }

    /// An app kept in the Dock: 0.3, a day before `now`.
    public static func dockApp(_ id: ItemID, now: Date) -> LearningSeed {
        LearningSeed(id: id, weight: 0.3, lastUsed: now.addingTimeInterval(-86_400))
    }

    /// An app running at first launch: 0.3, at `now`.
    public static func runningApp(_ id: ItemID, now: Date) -> LearningSeed {
        LearningSeed(id: id, weight: 0.3, lastUsed: now)
    }

    /// A document used in the last week: 0.15, at its last use.
    public static func recentDocument(_ id: ItemID, lastUsed: Date) -> LearningSeed {
        LearningSeed(id: id, weight: 0.15, lastUsed: lastUsed)
    }

    /// One seed per item: weights added up and capped at ``maximumWeight``, the latest use kept.
    /// Seeds with a weight that is not a positive number are dropped. Sorted by ID, so the result
    /// does not depend on the input order.
    static func merged(_ seeds: [LearningSeed]) -> [LearningSeed] {
        var byID: [ItemID: LearningSeed] = [:]
        for seed in seeds where seed.weight > 0 && seed.weight.isFinite {
            if var existing = byID[seed.id] {
                existing.weight = min(existing.weight + seed.weight, maximumWeight)
                existing.lastUsed = max(existing.lastUsed, seed.lastUsed)
                byID[seed.id] = existing
            } else {
                var capped = seed
                capped.weight = min(seed.weight, maximumWeight)
                byID[seed.id] = capped
            }
        }
        return byID.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }
}
