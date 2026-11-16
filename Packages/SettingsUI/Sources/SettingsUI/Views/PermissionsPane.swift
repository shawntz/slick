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
            ForEach(model.groups, id: \.group) { section in
                let permissions = section.entries.map(\.permission)
                ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                    Section {
                        PermissionRow(
                            permission: entry.permission, title: entry.title, status: entry.status,
                            reason: entry.permission == .fullDiskAccess
                                && PermissionGroup.listsFolderFullDiskAccessAllows(permissions)
                                ? PermissionGroup.fullDiskAccessCoversFolders : nil,
                            waitingSentence: entry.waitingSentence,
                            grant: { await model.grant(entry.permission) },
                            openSettings: { await model.openSettings(for: entry.permission) })
                        ForEach(entry.wants) { want in
                            LabeledContent {
                                Text(want.isFeatureEnabled ? "On" : "Off").foregroundStyle(.secondary)
                            } label: {
                                Text(want.featureName)
                                Text(want.reason)
                            }
                            // Under the permission's name, so the row reads as one of its reasons.
                            .padding(.leading, 30)
                        }
                    } header: {
                        // The group's heading, once, above its first permission.
                        if index == 0 { Text(section.group.title) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.watch() }
    }
}
