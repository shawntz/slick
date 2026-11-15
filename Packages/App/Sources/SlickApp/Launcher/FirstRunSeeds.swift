import AppKit
import CoreServices
import Foundation
import Kit
import Root

/// Light priors for the first launch, so the first suggestions are not empty: the apps kept in the
/// Dock, the apps running now and the use counts Spotlight keeps for apps in the system's app
/// folders. Nothing here can raise a permission prompt. Root calls ``gather()`` once, off the main
/// thread, and only in the live launcher; no test or isolated run calls it.
nonisolated enum FirstRunSeeds {
    /// An app with a use count from Spotlight.
    struct CountedApp: Equatable, Sendable {
        var bundleID: String
        var useCount: Int
        var lastUsed: Date?
    }

    /// The folders whose apps Spotlight is asked about. The home folder is left out.
    static let spotlightScopes = ["/Applications", "/System/Applications"]

    @concurrent static func gather() async -> [LearningSeed] {
        let now = Date()
        let running = await MainActor.run { runningBundleIDs() }
        return seeds(dock: dockBundleIDs(), running: running, counted: spotlightApps(), now: now)
    }

    /// The seeds for what was found, with Root's weights for each kind.
    static func seeds(dock: [String], running: [String], counted: [CountedApp], now: Date) -> [LearningSeed] {
        var seeds: [LearningSeed] = []
        seeds += dock.map { LearningSeed.dockApp(appID($0), now: now) }
        seeds += running.map { LearningSeed.runningApp(appID($0), now: now) }
        seeds += counted.filter { $0.useCount > 0 }.map {
            LearningSeed.countedApp(appID($0.bundleID), useCount: $0.useCount, lastUsed: $0.lastUsed ?? now)
        }
        return seeds
    }

    /// The item ID the Apps feature gives the first copy of an app.
    static func appID(_ bundleID: String) -> ItemID {
        ItemID(ItemID.ReservedNamespace.app, bundleID)
    }

    // MARK: Dock

    /// The bundle IDs of the apps kept in the Dock, in Dock order.
    static func dockBundleIDs() -> [String] {
        let value = CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString)
        return bundleIDs(fromDockTiles: value as? [Any] ?? [])
    }

    /// The bundle IDs in the Dock's `persistent-apps` list. Anything that is not a well-formed
    /// tile with a plausible bundle ID is skipped. Each ID appears once.
    static func bundleIDs(fromDockTiles tiles: [Any]) -> [String] {
        var seen: Set<String> = []
        return tiles.compactMap { tile in
            guard let tile = tile as? [String: Any], let data = tile["tile-data"] as? [String: Any],
                let id = data["bundle-identifier"] as? String, isBundleID(id), seen.insert(id).inserted
            else { return nil }
            return id
        }
    }

    /// Letters, digits, ".", "-" and "_", at most 255 characters, not starting with ".".
    static func isBundleID(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 255, !text.hasPrefix(".") else { return false }
        return text.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_")
        }
    }

    // MARK: Running apps

    /// The bundle IDs of the regular apps running now, except this one.
    @MainActor static func runningBundleIDs() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
            .filter { $0 != Brand.bundleID && isBundleID($0) }
    }

    // MARK: Spotlight

    /// Apps in ``spotlightScopes`` with a use count, from one synchronous Spotlight query.
    static func spotlightApps() -> [CountedApp] {
        let text = "kMDItemContentType == \"com.apple.application-bundle\" && kMDItemUseCount > 0"
        guard let query = MDQueryCreate(kCFAllocatorDefault, text as CFString, nil, nil) else { return [] }
        MDQuerySetSearchScope(query, spotlightScopes as CFArray, 0)
        MDQuerySetMaxCount(query, 1000)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var apps: [CountedApp] = []
        var seen: Set<String> = []
        for index in 0..<MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let id = MDItemCopyAttribute(item, kMDItemCFBundleIdentifier) as? String, isBundleID(id),
                seen.insert(id).inserted
            else { continue }
            let uses = (MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? NSNumber)?.intValue ?? 0
            let last = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
            apps.append(CountedApp(bundleID: id, useCount: uses, lastUsed: last))
        }
        return apps
    }
}
