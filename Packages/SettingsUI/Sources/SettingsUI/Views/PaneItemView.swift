import Kit
import SwiftUI

/// One item of a feature's declarative settings pane, drawn with the standard control for its
/// kind.
struct PaneItemView: View {
    @Bindable var item: PaneItemModel
    let icons: IconResolver

    var body: some View {
        switch item.control {
        case .toggle:
            Toggle(isOn: $item.bool) { TitleAndInfo(title: item.title, info: item.info) }
        case .picker:
            Picker(selection: $item.pickerIndex) {
                ForEach(Array(item.options.enumerated()), id: \.offset) { index, option in
                    Text(option.title).tag(Int?.some(index))
                }
            } label: {
                TitleAndInfo(title: item.title, info: item.info)
            }
        case .textField(_, let placeholder):
            // A bordered field of its own width, so a long value scrolls inside a box that reads as a
            // field, and a placeholder never reads as a value.
            LabeledContent {
                TextField(item.title, text: $item.text, prompt: placeholder.map { Text($0) })
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
            } label: {
                TitleAndInfo(title: item.title, info: item.info)
            }
        case .secret(_, let placeholder):
            SecretItemView(item: item, placeholder: placeholder)
        case .stepper(_, let range, let step, let unit):
            ValueStepper(
                title: item.title, info: item.info, value: $item.int, range: range, step: step,
                text: unit.map { "\(item.int) \($0)" } ?? "\(item.int)")
        case .hotkey:
            if let recorder = item.hotkey {
                LabeledContent {
                    HotkeyRecorder(model: recorder)
                } label: {
                    TitleAndInfo(title: item.title, info: item.info)
                }
            }
        case .button:
            if let info = item.info {
                LabeledContent {
                    ButtonItemView(item: item)
                } label: {
                    Text(info)
                }
            } else {
                HStack {
                    ButtonItemView(item: item)
                    Spacer()
                }
            }
        case .list:
            ListItemView(item: item)
        case .multiSelect:
            VStack(alignment: .leading, spacing: 6) {
                ListTitle(title: item.title, info: item.info)
                if item.isLoadingChoices && item.choices.isEmpty {
                    ProgressView().controlSize(.small)
                } else if item.choices.isEmpty {
                    Text("Nothing to choose from.").foregroundStyle(.secondary)
                }
                ForEach(item.choices, id: \.id) { choice in
                    Toggle(isOn: Binding(get: { item.isChosen(choice.id) }, set: { item.setChosen($0, choice.id) })) {
                        HStack(spacing: 6) {
                            if choice.icon != nil { IconView(icon: choice.icon, size: 16, resolver: icons) }
                            Text(choice.title)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        case .application:
            LabeledContent {
                HStack {
                    Text(item.applicationTitle ?? "None").foregroundStyle(.secondary)
                    Button("Choose…") { Task { await item.chooseApplication() } }
                    if item.applicationTitle != nil {
                        Button("Clear") { item.clearApplication() }
                    }
                }
            } label: {
                TitleAndInfo(title: item.title, info: item.info)
            }
        case .permission(let permission):
            PermissionRow(
                permission: permission, title: item.permissionTitle, status: item.permissionStatus,
                reason: item.info ?? item.permissionReason,
                waitingSentence: item.permissionWaitingSentence, grant: { await item.grant() },
                openSettings: { await item.openPermissionSettings() })
        case .note:
            Text(item.title).foregroundStyle(.secondary)
        }
    }
}

private struct ButtonItemView: View {
    let item: PaneItemModel

    var body: some View {
        HStack {
            Button(item.title, role: item.buttonStyle == .destructive ? .destructive : nil) {
                Task { await item.run() }
            }
            .disabled(item.isRunning)
            if item.isRunning { ProgressView().controlSize(.small) }
        }
    }
}

private struct SecretItemView: View {
    @Bindable var item: PaneItemModel
    let placeholder: String?

    var body: some View {
        LabeledContent {
            HStack {
                SecureField(item.title, text: $item.secretDraft, prompt: Text(prompt))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 160)
                    .onSubmit { Task { await item.saveSecret() } }
                Button("Save") { Task { await item.saveSecret() } }
                    .disabled(item.secretDraft.isEmpty)
                if item.hasSecret {
                    Button("Remove") { Task { await item.removeSecret() } }
                }
            }
        } label: {
            TitleAndInfo(title: item.title, info: item.info ?? "Kept in your keychain, never in settings files.")
        }
    }

    private var prompt: String {
        item.hasSecret ? "Saved. Type to replace." : (placeholder ?? "Not set")
    }
}

private struct ListItemView: View {
    @Bindable var item: PaneItemModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ListTitle(title: item.title, info: item.info)
            ForEach(item.listEntries, id: \.value) { entry in
                HStack {
                    Text(entry.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(entry.isMissing ? .secondary : .primary)
                    Spacer()
                    if entry.isMissing {
                        Text("Not installed").foregroundStyle(.secondary)
                    }
                    Button {
                        item.remove(entry.value)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(entry.label)")
                }
            }
            switch item.listKind {
            case .text:
                HStack {
                    TextField("New entry", text: $item.listDraft, prompt: Text(placeholder ?? "New entry"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { item.addDraft() }
                    Button("Add") { item.addDraft() }
                        .disabled(item.listDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            case .application:
                Button("Add App…") { Task { await item.addFromPicker() } }
            case .folder:
                Button("Add Folder…") { Task { await item.addFromPicker() } }
            }
        }
    }

    private var placeholder: String? {
        if case .list(_, _, let placeholder) = item.control { return placeholder }
        return nil
    }
}

/// The title of a list or a set of checkboxes, with its help sentence under it in the small grey
/// type every other help line in a form uses. A plain stack gets no form styling, so it sets it.
private struct ListTitle: View {
    let title: String
    let info: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let info {
                Text(info)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
