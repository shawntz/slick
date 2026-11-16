import Kit
import SwiftUI

struct PermissionsPane: View {
    let model: PermissionsModel

    var body: some View {
        Form {
            Section {
                Text("macOS asks you once for each permission. Nothing here asks until you press Allow.")
                    .foregroundStyle(.secondary)
            }
            if model.entries.isEmpty {
                Section {
                    Text("No feature needs a permission.").foregroundStyle(.secondary)
                }
            }
            ForEach(model.entries) { entry in
                Section {
                    PermissionRow(
                        permission: entry.permission, status: entry.status, waitingSentence: entry.waitingSentence,
                        grant: { await model.grant(entry.permission) },
                        openSettings: { await model.openSettings(for: entry.permission) })
                    ForEach(entry.wants) { want in
                        LabeledContent {
                            Text(want.isFeatureEnabled ? "On" : "Off").foregroundStyle(.secondary)
                        } label: {
                            Text(want.featureName)
                            Text(want.reason)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.watch() }
    }
}
