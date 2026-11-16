import KitHosting
import SwiftUI

struct GeneralPane: View {
    @Bindable var model: GeneralModel

    var body: some View {
        Form {
            Section("Launcher") {
                LabeledContent {
                    HotkeyRecorder(model: model.launcherHotkey, showsHeldNote: model.hotkeyWait == nil)
                } label: {
                    Text("Hotkey")
                    Text("Opens the launcher from any app.")
                }
                if let note = model.hotkeyWaitNote {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(note, systemImage: "hourglass")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(SpotlightShortcutGuide.openButton) { model.openKeyboardSettings() }
                    }
                }
                Toggle(isOn: $model.launchAtLogin) {
                    Text("Open at login")
                }
                Toggle(isOn: $model.showStatusItem) {
                    Text("Show in the menu bar")
                }
                if model.isUnreachable {
                    Label(
                        "With no hotkey and no menu bar item, nothing opens the launcher.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }
            Section("Panel") {
                Picker("Open on", selection: $model.panelScreen) {
                    ForEach(HostSettings.PanelScreen.allCases, id: \.self) { screen in
                        Text(GeneralModel.title(screen)).tag(screen)
                    }
                }
                Picker(selection: $model.panelSizing) {
                    ForEach(HostSettings.PanelSizing.allCases, id: \.self) { sizing in
                        Text(GeneralModel.title(sizing)).tag(sizing)
                    }
                } label: {
                    Text("Height")
                    Text("Full height never changes size while you type.")
                }
                ValueStepper(
                    title: "Visible rows", value: $model.visibleRows, range: GeneralModel.visibleRowRange, step: 1,
                    text: "\(model.visibleRows)")
                Picker(selection: $model.resetToRootAfter) {
                    ForEach(model.resetChoices) { choice in
                        Text(choice.title).tag(choice.seconds)
                    }
                } label: {
                    Text("Return to root search")
                    Text("How long the launcher keeps the page you left.")
                }
            }
            Section(UpdateStrings.section) {
                if model.updatesAvailable {
                    Toggle(isOn: $model.checksForUpdates) {
                        Text(UpdateStrings.automaticTitle)
                        Text(UpdateStrings.whatIsSent)
                    }
                    if let waiting = model.waitingUpdateText {
                        LabeledContent(waiting) {
                            Button(UpdateStrings.showUpdate) { model.checkForUpdatesNow() }
                                .disabled(!model.canCheckForUpdates)
                        }
                    }
                    LabeledContent(model.lastCheckText) {
                        Button(UpdateStrings.checkNow) { model.checkForUpdatesNow() }
                            .disabled(!model.canCheckForUpdates)
                    }
                } else {
                    Text(UpdateStrings.builtFromSource)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }
}
