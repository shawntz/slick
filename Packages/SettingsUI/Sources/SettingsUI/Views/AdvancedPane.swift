import Kit
import KitHosting
import SwiftUI

struct AdvancedPane: View {
    @Bindable var model: AdvancedModel

    var body: some View {
        Form {
            Section("Data") {
                LabeledContent("Data folder") {
                    Text(model.dataDirectoryText).textSelection(.enabled).truncationMode(.middle)
                }
                Button("Reveal in Finder") { Task { await model.revealDataDirectory() } }
            }
            Section("Panel") {
                Picker(selection: $model.summonStrategy) {
                    ForEach(HostSettings.SummonStrategy.allCases, id: \.self) { strategy in
                        Text(AdvancedModel.title(strategy)).tag(strategy)
                    }
                } label: {
                    Text("Summon")
                    Text("Keep Ready keeps the panel open but hidden. It appears faster when you press the hotkey.")
                }
            }
            Section {
                if model.linkAllowances.isEmpty {
                    Text("No command runs from links without asking.").foregroundStyle(.secondary)
                }
                ForEach(model.linkAllowances) { item in
                    LabeledContent {
                        Button("Remove") { model.removeLinkAllowance(item) }
                            .accessibilityLabel("Remove \(item.title)")
                    } label: {
                        Text(item.title)
                        Text(item.detail)
                    }
                }
            } header: {
                Text("Links")
            } footer: {
                Text(
                    "Links from web pages and other apps can run these commands without asking, but only with these exact arguments. Remove a command to be asked again."
                )
            }
            Section("Network") {
                Toggle(isOn: $model.fetchRemoteIcons) {
                    Text("Download website icons")
                    Text("When this is off, websites and scripts show plain icons. \(Brand.name) downloads no icons.")
                }
            }
            Section {
                Button("Reset All Settings…", role: .destructive) { Task { await model.resetAllSettings() } }
            } footer: {
                Text("Reset keeps your aliases, hotkeys, favorites, themes and what root search learned.")
            }
        }
        .formStyle(.grouped)
    }
}
