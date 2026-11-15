import Foundation
import Kit
import Synchronization
import os

/// Records what other apps copy. It handles each pasteboard entry in a `@concurrent` function, so
/// nothing it does runs on the main thread.
///
/// It stores only what ``PasteboardService/entries()`` hands over. The service has already dropped
/// concealed, transient and auto-generated content and what this app wrote itself; the recorder
/// never reads the pasteboard on its own.
nonisolated struct Recorder: Sendable {
    let store: HistoryStore
    let settings: FeatureSettings
    let clock: any ClockService
    /// Sent after the history changed.
    let changes: ChangeSignal
    let latest: LatestCopy
    let log: Logger

    /// Records every entry the stream delivers, until the calling task is cancelled.
    @concurrent func run(_ entries: AsyncStream<PasteboardEntry>) async {
        for await entry in entries {
            await record(entry)
        }
    }

    /// Records one entry unless recording is paused, the app that copied it is ignored, or it holds
    /// nothing worth keeping. Then applies retention. Returns the item's key when it was recorded.
    @concurrent @discardableResult
    func record(_ entry: PasteboardEntry) async -> ItemKey? {
        guard !settings[ClipboardSettings.isPaused], !isIgnored(entry.sourceBundleID),
            let capture = Capture(entry, maximumBytes: ClipboardSettings.maximumItemBytes)
        else { return nil }
        do {
            let key = try await store.record(capture, at: entry.date)
            latest.set(key, at: entry.date)
            try await store.prune(PrunePolicy(settings: settings, clock: clock))
            changes.send()
            return key
        } catch is CancellationError {
            return nil
        } catch {
            log.error("Could not record a copy: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    /// Applies retention now, as at launch or after the user shortened it. Sends ``changes`` when
    /// anything went.
    @concurrent func prune() async {
        do {
            if try await store.prune(PrunePolicy(settings: settings, clock: clock)) > 0 {
                changes.send()
            }
        } catch is CancellationError {
        } catch {
            log.error("Could not prune the history: \(String(describing: error), privacy: .private)")
        }
    }

    /// True when the copy came from an app on the ignore list. Bundle IDs compare without case.
    func isIgnored(_ bundleID: String?) -> Bool {
        guard let bundleID = bundleID?.lowercased() else { return false }
        return settings[ClipboardSettings.ignoredApps].contains { $0.lowercased() == bundleID }
    }
}

/// The last item the recorder saved and when, for the suggestion trigger. Kept in memory only, so
/// the suggestion follows a copy in this session and never one from before a relaunch.
nonisolated final class LatestCopy: Sendable {
    private let state = Mutex<(key: ItemKey, date: Date)?>(nil)

    var value: (key: ItemKey, date: Date)? {
        state.withLock { $0 }
    }

    func set(_ key: ItemKey, at date: Date) {
        state.withLock { $0 = (key, date) }
    }

    func clear() {
        state.withLock { $0 = nil }
    }
}
