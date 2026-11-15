import Foundation
import Kit

extension FileSearchFeature {
    /// The pane: root search, the protected places with a button each, the folders and names to
    /// add or skip, and the index with its status line, a rebuild button and what is stored where.
    /// Its text follows the index and the choices, because ``declarationChanges`` fires when they
    /// change.
    public var settingsPane: SettingsPane? {
        let states = placeStates()
        let placeButtons = ProtectedPlace.allCases.map { place in
            placeButton(place, state: states[place] ?? .notSearched)
        }
        return SettingsPane([
            SettingsSection(
                Strings.Settings.rootSection,
                items: [
                    .toggle(
                        Strings.Settings.showsInRoot, key: FileSearchSettings.showsInRoot,
                        info: Strings.Settings.showsInRootInfo)
                ]),
            SettingsSection(
                Strings.Settings.placesSection, footer: Strings.Settings.placesFooter,
                items: placeButtons + [
                    .button(
                        Strings.Places.searchAll, confirmation: Strings.Places.searchAllConfirmation,
                        info: Strings.Settings.searchAllInfo
                    ) { [self] context in
                        await askForAccess(ProtectedPlace.folders, context: context)
                        includePlaces(ProtectedPlace.folders)
                        context.showToast(.success(Strings.Places.searchingAll))
                    },
                    .permission(.fullDiskAccess, info: Strings.Settings.fullDiskAccessInfo),
                ]),
            SettingsSection(
                Strings.Settings.foldersSection,
                items: [
                    .list(
                        Strings.Settings.extraFolders, key: FileSearchSettings.extraFolders, itemKind: .folder,
                        info: Strings.Settings.extraFoldersInfo),
                    .list(
                        Strings.Settings.excludedFolders, key: FileSearchSettings.excludedFolders, itemKind: .folder,
                        info: Strings.Settings.excludedFoldersInfo),
                    .list(
                        Strings.Settings.excludedNames, key: FileSearchSettings.excludedNames, itemKind: .text,
                        placeholder: Strings.Settings.excludedNamesPlaceholder, info: Strings.Settings.excludedNamesInfo
                    ),
                    .toggle(
                        Strings.Settings.includesHidden, key: FileSearchSettings.includesHidden,
                        info: Strings.Settings.includesHiddenInfo),
                ]),
            SettingsSection(
                Strings.Settings.indexSection,
                items: [
                    .note(indexNote),
                    .button(Strings.Settings.rebuild, info: Strings.Settings.rebuildInfo) { [self] context in
                        let outcome = await rebuild()
                        if outcome.failed {
                            context.showToast(
                                .failure(Strings.Index.rebuildFailed, message: Strings.Index.rebuildFailedMessage))
                        } else {
                            context.showToast(
                                .success(
                                    Strings.Index.rebuilt,
                                    message: Strings.Index.holds(
                                        controller.summary.count, locale: self.context.clock.locale)
                                ))
                        }
                    },
                    .note(Strings.Settings.storage(storageLocation)),
                ]),
        ])
    }

    /// One button per place: search it, or stop searching it. The info says where it stands.
    private func placeButton(_ place: ProtectedPlace, state: PlaceState) -> SettingsItem {
        let info = Strings.Places.explanation(place, state)
        if state == .searched {
            return .button(Strings.Places.stop(place), info: info) { [self] context in
                turnOff(place)
                context.showToast(.success(Strings.Places.stopped(place)))
            }
        }
        return .button(
            Strings.Places.search(place), confirmation: place == .iCloudDrive ? Strings.Places.iCloudConfirmation : nil,
            info: info
        ) { [self] context in
            await askForAccess([place], context: context)
            includePlaces([place])
            let granted = place.permission.map { self.context.permissions.isGranted($0) } ?? true
            context.showToast(
                granted
                    ? .success(Strings.Places.searching(place))
                    : Toast(.info, Strings.Places.needsAccess(place), message: Strings.Places.needsAccessMessage))
        }
    }

    /// The status line in sentences: how much the index holds and when it last changed.
    private var indexNote: String {
        let summary = controller.summary
        guard summary.phase == .ready, let updated = summary.updatedAt else { return summaryLine + "." }
        let clock = context.clock
        return Strings.Index.holds(summary.count, locale: clock.locale) + " "
            + Strings.Settings.lastUpdated(updated, locale: clock.locale, timeZone: clock.timeZone)
    }

    /// Where the index file is, as people read it.
    private var storageLocation: String {
        let home = Paths.normalized(context.storage.homeDirectory.path(percentEncoded: false), home: nil) ?? "/"
        return Paths.display(Paths.parent(of: controller.file), home: home)
    }
}
