import Kit
import SwiftUI

struct FeaturesPane: View {
    @Bindable var model: FeaturesModel
    let icons: IconResolver

    var body: some View {
        NavigationStack(path: $model.path) {
            Form {
                Section {
                    ForEach(model.features) { feature in
                        HStack(spacing: 10) {
                            NavigationLink(value: feature.id) {
                                FeatureLabel(feature: feature, icons: icons)
                            }
                            Toggle(
                                "Enable \(feature.name)",
                                isOn: Binding(
                                    get: { model.isEnabled(feature.id) },
                                    set: { enabled in Task { await model.setEnabled(enabled, feature: feature.id) } })
                            )
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }
                    }
                } footer: {
                    Text("A feature that is off leaves root search and stops its background work.")
                }
            }
            .formStyle(.grouped)
            .navigationDestination(for: String.self) { featureID in
                FeatureDetailPane(model: model.page(featureID), icons: icons)
            }
        }
    }
}

private struct FeatureLabel: View {
    let feature: FeaturesModel.Summary
    let icons: IconResolver

    var body: some View {
        HStack(spacing: 10) {
            IconView(icon: feature.icon, size: 24, resolver: icons)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(feature.name)
                    if let status = feature.status, status.level != .info {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(status.level == .failure ? .red : .orange)
                            .accessibilityLabel(status.title)
                    }
                }
                if !feature.summary.isEmpty {
                    Text(feature.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}
