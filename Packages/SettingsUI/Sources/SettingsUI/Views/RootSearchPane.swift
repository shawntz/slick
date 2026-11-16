import Kit
import SwiftUI

struct RootSearchPane: View {
    @Bindable var model: RootSearchModel
    let icons: IconResolver

    var body: some View {
        Form {
            Section("When the search field is empty") {
                Toggle("Show suggestions", isOn: $model.showSuggestions)
                ValueStepper(
                    title: "Suggestions", value: $model.suggestionCount, range: RootSearchModel.suggestionRange,
                    step: 1,
                    text: "\(model.suggestionCount)"
                )
                .disabled(!model.showSuggestions)
                Toggle("Show favorites", isOn: $model.showFavorites)
            }
            Section {
                if model.favorites.isEmpty {
                    Text("Add a favorite from any result's actions.").foregroundStyle(.secondary)
                }
                ForEach(Array(model.favorites.enumerated()), id: \.element.id) { index, item in
                    ItemRow(item: item, icons: icons) {
                        reorderButtons(index: index, count: model.favorites.count) {
                            model.moveFavorite(item.id, by: $0)
                        }
                        Button {
                            model.removeFavorite(item.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(item.title) from favorites")
                    }
                }
                .onMove { model.moveFavorites(from: $0, to: $1) }
            } header: {
                Text("Favorites")
            }
            Section("While typing") {
                Toggle(isOn: $model.inlineCompletion) {
                    Text("Complete the top result inline")
                    Text("Shows the rest of the top title after what you typed. Tab accepts it.")
                }
                Picker(selection: $model.tabCommand) {
                    Text("Nothing").tag(ItemID?.none)
                    ForEach(model.tabCandidates) { item in
                        Text(item.title).tag(ItemID?.some(item.id))
                    }
                } label: {
                    Text("Tab runs")
                    Text("When no completion shows, Tab runs this command with what you typed.")
                }
            }
            Section {
                if model.fallbacks.isEmpty {
                    Text("No feature that is on offers a fallback.").foregroundStyle(.secondary)
                }
                ForEach(Array(model.fallbacks.enumerated()), id: \.element.id) { index, fallback in
                    ItemRow(item: fallback.item, icons: icons) {
                        reorderButtons(index: index, count: model.fallbacks.count) {
                            model.moveFallback(fallback.id, by: $0)
                        }
                        Toggle(
                            "Show \(fallback.item.title) under the results",
                            isOn: Binding(
                                get: { fallback.isOn },
                                set: { model.setFallback(fallback.id, isOn: $0) })
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }
                .onMove { model.moveFallbacks(from: $0, to: $1) }
            } header: {
                Text("Fallback commands")
            } footer: {
                Text("The ones that are on show under the results, in this order. Each runs with what you typed.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func reorderButtons(index: Int, count: Int, move: @escaping (Int) -> Void) -> some View {
        Button {
            move(-1)
        } label: {
            Image(systemName: "chevron.up")
        }
        .buttonStyle(.borderless)
        .disabled(index == 0)
        .accessibilityLabel("Move up")
        Button {
            move(1)
        } label: {
            Image(systemName: "chevron.down")
        }
        .buttonStyle(.borderless)
        .disabled(index == count - 1)
        .accessibilityLabel("Move down")
    }
}

/// An item with its icon and title, and trailing controls.
struct ItemRow<Trailing: View>: View {
    let item: RootSearchModel.Item
    let icons: IconResolver
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            IconView(icon: item.icon, size: 18, resolver: icons)
            Text(item.title)
                .foregroundStyle(item.isAvailable ? .primary : .secondary)
            if !item.isAvailable {
                Text("Off").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
    }
}
