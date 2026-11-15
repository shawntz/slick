import Foundation
import Kit

/// Open Trash, Empty Trash, Eject All Disks and Toggle Hidden Files.
extension SystemFeature {
    var housekeepingCommands: [Command] {
        [
            Command(
                id: "open-trash", title: Strings.Trash.openTitle, icon: .symbol("trash.circle"),
                keywords: Strings.Trash.openKeywords
            ) { context in
                // Finder shows the Trash for its folder. Opening it reads nothing in it, so it needs
                // no permission.
                let trash = context.storage.homeDirectory.appending(path: ".Trash", directoryHint: .isDirectory)
                do {
                    try await context.workspace.open(trash)
                } catch {
                    throw ActionFailure(Strings.Trash.notOpened)
                }
                return .close()
            },
            Command(
                id: "empty-trash", title: Strings.Trash.title, icon: .symbol("trash"), keywords: Strings.Trash.keywords,
                runPolicy: .dropWhileRunning
            ) { context in
                try await self.emptyTrash(context)
            },
            Command(
                id: "eject-all-disks", title: Strings.Eject.title, icon: .symbol("eject"),
                keywords: Strings.Eject.keywords, runPolicy: .dropWhileRunning
            ) { context in
                try await self.ejectAll(context)
            },
            Command(
                id: "toggle-hidden-files", title: Strings.HiddenFiles.title, icon: .symbol("eye"),
                keywords: Strings.HiddenFiles.keywords
            ) { context in
                try await self.toggleHiddenFiles(context)
            },
        ]
    }

    /// Counts the items, asks with the count, then deletes them with the panel closed. The Trash on
    /// other disks is included only with Full Disk Access, which covers removable volumes too, so
    /// reading them can never raise a system prompt.
    private func emptyTrash(_ context: ActionContext) async throws -> ActionOutcome {
        let includingVolumes = context.permissions.isGranted(.fullDiskAccess)
        let housekeeping = housekeeping
        return try await SystemFailure.handle(Strings.Trash.words) {
            let count = try await housekeeping.trashItemCount(includingVolumes: includingVolumes)
            guard count > 0 else { return .close(hud: HUD(Strings.Trash.alreadyEmpty)) }
            let confirmation = Confirmation(
                Strings.Trash.question, message: Strings.Trash.message(items: count),
                confirmTitle: Strings.Trash.confirm, isDestructive: true)
            guard await context.confirm(confirmation) else { return .keepOpen }
            context.dismiss()
            let result = try await housekeeping.emptyTrash(includingVolumes: includingVolumes)
            guard result.failed == 0 else {
                throw ActionFailure(
                    Strings.Trash.notDeleted(items: result.failed), message: Strings.Trash.notDeletedReason)
            }
            return .close(hud: .success(Strings.Trash.emptied(items: result.deleted)))
        }
    }

    /// Finds the disks to eject, asks with their names, then ejects each with the panel closed.
    private func ejectAll(_ context: ActionContext) async throws -> ActionOutcome {
        let housekeeping = housekeeping
        let locale = context.clock.locale
        let ejectsNetwork = context.settings[SystemSettings.ejectsNetworkVolumes]
        let keep = context.settings[SystemSettings.neverEject]
        return try await SystemFailure.handle(Strings.Eject.words) {
            let mounted = try await housekeeping.ejectableDisks()
            let targets = Self.disksToEject(mounted, ejectsNetwork: ejectsNetwork, keep: keep)
            guard !targets.isEmpty else { return .close(hud: HUD(Strings.Eject.nothingToEject)) }
            let names = targets.map(\.name)
            let confirmation = Confirmation(
                Strings.Eject.question(disks: targets.count),
                message: Strings.Eject.message(names: names, locale: locale),
                confirmTitle: Strings.Eject.confirm, suppressionKey: "eject-all")
            guard await context.confirm(confirmation) else { return .keepOpen }
            context.dismiss()
            // A disk left mounted on purpose may share a drive with one being ejected; then only the
            // volumes are unmounted and the drive stays.
            let keepsLocalDisk = mounted.contains { !$0.isNetwork && !targets.contains($0) }
            var failed: [String] = []
            for disk in targets {
                do {
                    try await housekeeping.eject(disk, keepingOtherPartitions: keepsLocalDisk)
                } catch {
                    failed.append(disk.name)
                }
            }
            guard failed.isEmpty else {
                throw ActionFailure(
                    Strings.Eject.notEjected(names: failed, locale: locale), message: Strings.Eject.notEjectedReason)
            }
            return .close(hud: .success(Strings.Eject.ejected(names: names, locale: locale)))
        }
    }

    /// The disks Eject All Disks takes: every ejectable disk, without network volumes unless the
    /// setting allows them, and without the names the user keeps. See ``DiskNamePattern``.
    nonisolated static func disksToEject(_ disks: [Disk], ejectsNetwork: Bool, keep: [String]) -> [Disk] {
        disks.filter { disk in
            (ejectsNetwork || !disk.isNetwork) && !DiskNamePattern.matches(disk.name, any: keep)
        }
    }

    /// Closes the panel first, since Finder can take a few seconds to quit, then reports with a HUD.
    private func toggleHiddenFiles(_ context: ActionContext) async throws -> ActionOutcome {
        let housekeeping = housekeeping
        return try await SystemFailure.handle(Strings.HiddenFiles.words) {
            context.dismiss()
            let shows = try await !housekeeping.showsHiddenFiles()
            let restarted = try await housekeeping.setShowsHiddenFiles(shows)
            return .close(hud: HUD(Strings.HiddenFiles.done(shows: shows, finderRestarted: restarted)))
        }
    }
}
