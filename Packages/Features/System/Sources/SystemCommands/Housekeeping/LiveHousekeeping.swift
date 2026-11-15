import AppKit
import Foundation
import Kit

/// The real Trash, disks and Finder setting. Used only when the app runs for a person.
///
/// - The Trash: Finder counts and empties it through Apple Events, as its own Empty Trash menu item
///   does. Finder's Trash takes in every volume and iCloud Drive, and Finder deals with locked items
///   and items in use. This needs Automation for Finder only, never Full Disk Access, and the app
///   never reads a Trash folder itself.
/// - Disks: `FileManager.mountedVolumeURLs` and `FileManager.unmountVolume`, without UI, so the
///   command reports failures in its own words.
/// - Hidden files: `CFPreferences` writes Finder's `AppleShowAllFiles`, then Finder is asked to quit
///   with `NSRunningApplication.terminate()` and opened again with `NSWorkspace`. Finder reads the
///   setting only when it starts.
nonisolated final class LiveHousekeeping: HousekeepingService {
    static let finderID = "com.apple.finder"
    static let finder = URL(filePath: "/System/Library/CoreServices/Finder.app", directoryHint: .isDirectory)
    private static let showAllFilesKey = "AppleShowAllFiles"

    init() {}

    // MARK: - Trash

    @concurrent func trashItemCount() async throws -> Int? {
        let target = try Self.finderTarget()
        do {
            let reply = try AppleEvents.sendForResult(Self.countEvent(to: target), bundleID: Self.finderID)
            guard let number = reply?.coerce(toDescriptorType: DescType(typeSInt32)) else { return nil }
            return Int(number.int32Value)
        } catch SystemFailure.failed {
            // Finder did not count. The command then asks without a number.
            return nil
        }
    }

    @concurrent func emptyTrash() async throws -> Bool {
        let target = try Self.finderTarget()
        // Finder's "warns before emptying" (warn) would ask a second time after the command has
        // asked. It is turned off for this one empty and put back at once.
        let warns = Self.warnsBeforeEmptying
        let warned = (try? AppleEvents.get(warns, from: target, bundleID: Self.finderID))?.booleanValue ?? false
        if warned {
            try? AppleEvents.set(warns, to: NSAppleEventDescriptor(boolean: false), in: target, bundleID: Self.finderID)
        }
        defer {
            if warned {
                try? AppleEvents.set(
                    warns, to: NSAppleEventDescriptor(boolean: true), in: target, bundleID: Self.finderID)
            }
        }
        do {
            _ = try AppleEvents.sendForResult(Self.emptyEvent(to: target), bundleID: Self.finderID)
            return true
        } catch SystemFailure.failed(let code) where code == Int32(errAETimeout) {
            // A large Trash takes Finder longer than the wait. Finder goes on and shows its progress.
            return false
        }
    }

    /// The trash (trsh) property of Finder's application object, from Finder.sdef.
    static var trash: NSAppleEventDescriptor { AppleEvents.property("trsh", of: .null()) }

    /// The trash's "warns before emptying" (warn) property, from Finder.sdef.
    static var warnsBeforeEmptying: NSAppleEventDescriptor { AppleEvents.property("warn", of: trash) }

    /// "count each item of trash": the core suite's count event (core/cnte) with the class item
    /// (cobj), from Finder.sdef.
    static func countEvent(to target: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let event = AppleEvents.event(AEEventClass(kAECoreSuite), AEEventID(kAECountElements), to: target)
        event.setParam(trash, forKeyword: keyDirectObject)
        event.setParam(
            NSAppleEventDescriptor(typeCode: AppleEvents.fourCharCode("cobj")), forKeyword: AEKeyword(keyAEObjectClass))
        return event
    }

    /// "empty trash": Finder's empty event (fndr/empt), from Finder.sdef.
    static func emptyEvent(to target: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let event = AppleEvents.event(AppleEvents.fourCharCode("fndr"), AppleEvents.fourCharCode("empt"), to: target)
        event.setParam(trash, forKeyword: keyDirectObject)
        return event
    }

    /// Finder, once it is known to run and to take events from this app. Never prompts: a missing
    /// Automation grant comes back as ``SystemFailure/permissionMissing(_:)``.
    private static func finderTarget() throws -> NSAppleEventDescriptor {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: finderID).isEmpty else {
            throw SystemFailure.notFound
        }
        let target = AppleEvents.target(bundleID: finderID)
        try AppleEvents.checkPermission(for: target, bundleID: finderID)
        return target
    }

    // MARK: - Disks

    @concurrent func ejectableDisks() async throws -> [Disk] {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeIsRootFileSystemKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
            .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
        ]
        let volumes =
            FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes])
            ?? []
        return volumes.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                values.volumeIsRootFileSystem != true, values.volumeIsBrowsable != false,
                Self.canEject(path: url.path)
            else { return nil }
            let isLocal = values.volumeIsLocal ?? true
            let ejectable =
                values.volumeIsEjectable == true || values.volumeIsRemovable == true
                || values.volumeIsInternal == false || !isLocal
            guard ejectable else { return nil }
            return Disk(
                name: values.volumeLocalizedName ?? url.lastPathComponent, path: url.path, isNetwork: !isLocal)
        }
    }

    @concurrent func eject(_ disk: Disk, keepingOtherPartitions: Bool) async throws {
        guard Self.canEject(path: disk.path) else { throw SystemFailure.unavailable }
        var options: FileManager.UnmountOptions = [.withoutUI]
        if !disk.isNetwork && !keepingOtherPartitions {
            options.insert(.allPartitionsAndEjectDisk)
        }
        do {
            try await FileManager.default.unmountVolume(
                at: URL(filePath: disk.path, directoryHint: .isDirectory), options: options)
        } catch {
            throw SystemFailure.failed(code: Int32(truncatingIfNeeded: (error as NSError).code))
        }
    }

    /// Never the startup disk or anything the system mounts for itself.
    static func canEject(path: String) -> Bool {
        let standardized = URL(filePath: path).standardizedFileURL.path
        return standardized != "/" && !standardized.hasPrefix("/System/")
    }

    // MARK: - Hidden files

    @concurrent func showsHiddenFiles() async throws -> Bool {
        CFPreferencesAppSynchronize(Self.finderID as CFString)
        return Self.isOn(CFPreferencesCopyAppValue(Self.showAllFilesKey as CFString, Self.finderID as CFString))
    }

    @concurrent func setShowsHiddenFiles(_ shows: Bool) async throws -> Bool {
        let domain = Self.finderID as CFString
        CFPreferencesSetAppValue(Self.showAllFilesKey as CFString, shows as CFPropertyList, domain)
        guard CFPreferencesAppSynchronize(domain) else { throw SystemFailure.failed(code: 0) }
        return try await Self.restartFinder()
    }

    /// Finder stores the setting as a Boolean, or as "YES" or "1" when someone wrote it with
    /// `defaults` as a string.
    static func isOn(_ value: CFPropertyList?) -> Bool {
        switch value {
        case let number as NSNumber: number.boolValue
        case let text as String: ["1", "yes", "true"].contains(text.lowercased())
        default: false
        }
    }

    /// Asks Finder to quit, waits up to five seconds for it to go, then opens it again in the
    /// background. The wait checks the old process IDs, since the system may start a new Finder by
    /// itself. Returns false when Finder is still running at the deadline, as when it is busy
    /// copying; it then picks up the setting the next time it opens.
    private static func restartFinder() async throws -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: finderID)
        let pids = running.map(\.processIdentifier).filter { $0 > 1 }
        for finder in running {
            finder.terminate()
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        // Signal 0 sends nothing; it only asks whether the process still exists.
        while clock.now < deadline, pids.contains(where: { kill($0, 0) == 0 }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !pids.contains(where: { kill($0, 0) == 0 }) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: finder, configuration: configuration)
        } catch {
            throw SystemFailure.failed(code: Int32(truncatingIfNeeded: (error as NSError).code))
        }
        return true
    }
}
