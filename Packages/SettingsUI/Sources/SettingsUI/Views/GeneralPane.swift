import KitHosting
import SwiftUI

struct GeneralPane: View {
    @Bindable var model: GeneralModel

    var body: some View {
        Form {
            Section("Launcher") {
                LabeledContent {
                    HotkeyRecorder(model: model.launcherHotkey)
                } label: {
                    Text("Hotkey")
                    Text("Opens the launcher from any app.")
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
        }
        .formStyle(.grouped)
    }
}
