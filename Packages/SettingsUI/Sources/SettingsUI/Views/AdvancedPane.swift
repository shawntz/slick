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
                    Text("Keep ready leaves the panel in place, invisible, so it shows on the next frame.")
                }
            }
            Section("Network") {
                Toggle(isOn: $model.fetchRemoteIcons) {
                    Text("Download website icons")
                    Text("When off, websites and scripts show generic icons and no request is made for them.")
                }
            }
            Section {
                Button("Reset All Settings…", role: .destructive) { Task { await model.resetAllSettings() } }
            } footer: {
                Text("Aliases, hotkeys, favorites, your themes and what was learned are kept.")
            }
        }
        .formStyle(.grouped)
    }
}
