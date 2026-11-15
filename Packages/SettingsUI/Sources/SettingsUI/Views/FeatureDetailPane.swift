import Kit
import KitHosting
import SwiftUI

struct FeatureDetailPane: View {
    @Bindable var model: FeatureDetailModel
    let icons: IconResolver

    var body: some View {
        Form {
            if let entry = model.entry {
                Section {
                    HStack(spacing: 12) {
                        IconView(icon: entry.manifest.icon, size: 36, resolver: icons)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.manifest.name).font(.title3).fontWeight(.semibold)
                            if !entry.manifest.summary.isEmpty {
                                Text(entry.manifest.summary).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Toggle(
                            "Enable \(entry.manifest.name)",
                            isOn: Binding(
                                get: { model.isEnabled }, set: { enabled in Task { await model.setEnabled(enabled) } })
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
                if let status = model.status {
                    Section {
                        StatusBanner(status: status, missing: model.missingStatusPermissions) { await model.grant($0) }
                    }
                }
                if !model.commands.isEmpty {
                    Section {
                        ForEach(model.commands) { command in
                            CommandRow(command: command, icons: icons, featureIcon: entry.manifest.icon)
                        }
                    } header: {
                        Text("Commands")
                    } footer: {
                        Text("Type an alias to reach a command first. A hotkey runs it from any app.")
                    }
                }
                if !model.presets.isEmpty {
                    Section {
                        ForEach(model.presets, id: \.id) { preset in
                            LabeledContent(preset.name) {
                                Button("Review and Apply…") { model.review(preset) }
                            }
                        }
                    } header: {
                        Text("Hotkey presets")
                    } footer: {
                        Text("A preset sets hotkeys for several commands at once. You see every change first.")
                    }
                }
                ForEach(model.sections) { section in
                    Section {
                        ForEach(section.items) { item in
                            PaneItemView(item: item, icons: icons)
                        }
                    } header: {
                        if let title = section.title { Text(title) }
                    } footer: {
                        if let footer = section.footer { Text(footer) }
                    }
                }
            } else {
                Text("This feature is no longer registered.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(model.name)
        .task { await model.appeared() }
        .sheet(item: $model.presetReview) { review in
            PresetReviewSheet(review: review, apply: model.applyReviewedPreset, cancel: model.cancelPresetReview)
        }
    }
}

private struct CommandRow: View {
    @Bindable var command: CommandRowModel
    let icons: IconResolver
    let featureIcon: Icon
    @FocusState private var aliasFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconView(icon: command.icon ?? featureIcon, size: 20, resolver: icons)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(command.title)
                if let subtitle = command.subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            TextField("Alias", text: $command.aliasDraft, prompt: Text("Alias"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .focused($aliasFocused)
                .onSubmit { command.commitAlias() }
                .onChange(of: aliasFocused) { _, focused in if !focused { command.commitAlias() } }
                .accessibilityLabel("Alias for \(command.title)")
            HotkeyRecorder(model: command.hotkey)
            Toggle("Enable \(command.title)", isOn: $command.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// Every change a hotkey preset would make, before it is applied.
private struct PresetReviewSheet: View {
    let review: PresetReview
    let apply: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Apply \(review.preset.name)?").font(.title3).fontWeight(.semibold)
            Text(
                review.isClean
                    ? "These hotkeys are free."
                    : "Some hotkeys are in use. Applying takes them from your other items. Hotkeys that cannot be taken are skipped."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Command").fontWeight(.medium)
                    Text("Hotkey").fontWeight(.medium)
                    Text("In use by").fontWeight(.medium)
                }
                Divider()
                ForEach(review.bindings) { binding in
                    GridRow {
                        Text(binding.title)
                        Text(binding.combo.displayString).monospaced()
                        if binding.conflicts.isEmpty {
                            Text("Free").foregroundStyle(.secondary)
                        } else {
                            Label(
                                binding.conflictText,
                                systemImage: binding.isBlocked ? "nosign" : "arrow.left.arrow.right"
                            )
                            .foregroundStyle(binding.isBlocked ? .red : .orange)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Apply", action: apply)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460)
    }
}
