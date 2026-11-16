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
                    "A web page or another app can open a link that runs these commands without asking, with exactly these arguments. Remove one to be asked again."
                )
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
