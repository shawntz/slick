import Kit
import KitHosting
import SwiftUI

struct LearningPane: View {
    @Bindable var model: LearningModel
    let icons: IconResolver

    var body: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Everything learned stays on this Mac.").fontWeight(.semibold)
                        Text(
                            "Root search learns which result you pick for each search. It puts that result higher next time. Nothing is sent anywhere."
                        )
                        .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.shield").foregroundStyle(.green)
                }
                LabeledContent("Learned", value: model.summaryText)
                LabeledContent("Size on disk", value: model.sizeText)
                if let since = model.sinceText {
                    Text(since).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle(isOn: $model.isPaused) {
                    Text("Pause learning")
                    Text("Nothing new is recorded. What was learned still ranks.")
                }
            }
            Section("Most Used") {
                if model.topItems.isEmpty {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                }
                ForEach(model.topItems) { item in
                    HStack(spacing: 8) {
                        IconView(icon: model.icon(for: item), size: 18, resolver: icons)
                        Text(item.title)
                        Spacer()
                        Text(item.useCount == 1 ? "1 run" : "\(item.useCount) runs").foregroundStyle(.secondary)
                        Button {
                            Task { await model.forget(item: item.id) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Forget \(item.title)")
                        .help("Forget this item everywhere")
                    }
                }
            }
            Section {
                TextField("Filter", text: $model.filter, prompt: Text("Filter searches"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                if model.queries.isEmpty {
                    Text(model.filter.isEmpty ? "Nothing learned yet." : "No search matches.").foregroundStyle(
                        .secondary)
                }
                ForEach(model.queries) { query in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(query.query).monospaced().frame(minWidth: 70, alignment: .leading)
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                        if let holder = model.bandHolder(of: query) {
                            Image(systemName: "pin.fill")
                                .foregroundStyle(.secondary)
                                .help("\(holder.title) ranks first for \(query.query)")
                                .accessibilityLabel("\(holder.title) ranks first")
                        }
                        favoredText(query)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            Task { await model.forget(query: query.query) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Forget what \(query.query) learned")
                    }
                    .accessibilityElement(children: .contain)
                }
            } header: {
                Text("Learned Searches")
            } footer: {
                Text(
                    "Each row shows what a typed search learned. The pinned result ranks first, even above an exact name match. Deleting a row makes that search rank by text again."
                )
            }
            if !model.switchedOffTriggers.isEmpty {
                Section {
                    ForEach(model.switchedOffTriggers) { trigger in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.triggerTitle(trigger))
                                Text(model.triggerDetail(trigger))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Turn On") {
                                Task { await model.turnOn(trigger) }
                            }
                            .accessibilityLabel(
                                "Turn on \(model.triggerTitle(trigger)) from \(model.featureName(of: trigger))")
                        }
                    }
                } header: {
                    Text("Suggestions That Turned Off")
                } footer: {
                    Text(
                        "These suggestions turned off because you rarely picked them. Turning one on lets it learn again."
                    )
                }
            }
            Section {
                Button("Erase Everything Learned…", role: .destructive) {
                    Task { await model.eraseAll() }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: model.changeCount) { await model.load() }
    }

    /// The items a query favors, strongest first, with the one that ranks first in bold.
    private func favoredText(_ query: LearnedQuery) -> Text {
        var text = Text(verbatim: "")
        for (index, item) in query.items.enumerated() {
            let title = item.holdsBand ? Text(verbatim: item.title).bold() : Text(verbatim: item.title)
            text = index == 0 ? title : Text("\(text), \(title)")
        }
        return text.foregroundStyle(.secondary)
    }
}
