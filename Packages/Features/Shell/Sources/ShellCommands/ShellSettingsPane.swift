import Foundation
import Kit

/// The feature's pane in the settings window.
enum ShellSettingsPane {
    static func pane(history: ShellHistory) -> SettingsPane {
        SettingsPane([
            SettingsSection(
                Strings.Settings.runSection, footer: Strings.Settings.runFooter,
                items: [
                    .picker(
                        Strings.Settings.shell, key: ShellSettings.shell, info: Strings.Settings.shellInfo,
                        titles: Strings.Settings.shellOption),
                    .textField(
                        Strings.Settings.workingFolder, key: ShellSettings.workingFolder,
                        placeholder: Strings.Settings.workingFolderPlaceholder, info: Strings.Settings.workingFolderInfo
                    ),
                    .button(Strings.Settings.chooseFolder) { context in
                        try await chooseFolder(context)
                    },
                    .picker(
                        Strings.Settings.outputLimit, key: ShellSettings.outputLimit,
                        info: Strings.Settings.outputLimitInfo, titles: Strings.Settings.outputLimitOption),
                ]),
            SettingsSection(
                Strings.Settings.historySection, footer: Strings.Settings.historyFooter(appName: Brand.name),
                items: [
                    .toggle(
                        Strings.Settings.keepsHistory, key: ShellSettings.keepsHistory,
                        info: Strings.Settings.keepsHistoryInfo),
                    .button(
                        Strings.Actions.clearHistory, style: .destructive, confirmation: HistoryList.clearConfirmation
                    ) { context in
                        await history.clear()
                        context.showToast(.success(Strings.Actions.cleared))
                    },
                ]),
        ])
    }

    /// Lets the user pick the working folder in an open dialog and stores it, as "~/x" inside the
    /// home folder.
    static func chooseFolder(_ context: ActionContext) async throws {
        let chosen = await context.fileDialogs.chooseFiles(
            OpenDialogRequest(
                title: Strings.Settings.chooseFolderTitle, canChooseDirectories: true, canChooseFiles: false))
        guard let folder = chosen.first else { return }
        guard folder.hasDirectoryPath else {
            throw ActionFailure(Strings.Settings.notAFolder, message: Strings.Settings.notAFolderMessage)
        }
        let value = RunSetup.settingValue(for: folder, home: context.storage.homeDirectory)
        context.feature.settings[ShellSettings.workingFolder] = value
        context.showToast(.success(Strings.Settings.folderChosen))
    }
}
