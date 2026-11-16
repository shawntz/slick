import Foundation
import Kit
import KitHosting
import Observation

/// The root search pane: suggestions, favorites, inline completion, the fallbacks with a switch and
/// a place each, and the Tab command.
@Observable final class RootSearchModel {
    /// An item as the pane lists it.
    struct Item: Identifiable, Hashable {
        var id: ItemID
        var title: String
        var icon: Icon?
        /// False when the item's command is gone or switched off.
        var isAvailable: Bool
    }

    static let suggestionRange = 1...10

    @ObservationIgnored private let context: SettingsContext
    @ObservationIgnored private let tasks = TaskBag()
    private let revision = Revision()

    init(context: SettingsContext) {
        self.context = context
        tasks.follow(HostSettings.allKeys, in: context.general, bumping: revision)
        tasks.follow(context.preferences.changes, bumping: revision)
        tasks.follow(context.directory.changes, bumping: revision)
    }

    private var general: FeatureSettings { context.general }

    private func read<Value>(_ key: SettingKey<Value>) -> Value {
        revision.track()
        return general[key]
    }

    private func write<Value>(_ key: SettingKey<Value>, _ value: Value) {
        general[key] = value
        revision.bump()
    }

    // MARK: Empty query

    var showSuggestions: Bool {
        get { read(HostSettings.showSuggestions) }
        set { write(HostSettings.showSuggestions, newValue) }
    }

    var suggestionCount: Int {
        get { read(HostSettings.suggestionCount) }
        set {
            write(
                HostSettings.suggestionCount,
                min(max(newValue, Self.suggestionRange.lowerBound), Self.suggestionRange.upperBound))
        }
    }

    var showFavorites: Bool {
        get { read(HostSettings.showFavorites) }
        set { write(HostSettings.showFavorites, newValue) }
    }

    /// The favorites in the user's order.
    var favorites: [Item] {
        revision.track()
        return context.preferences.favorites.map(item)
    }

    func moveFavorites(from offsets: IndexSet, to destination: Int) {
        var ids = context.preferences.favorites
        ids.reorder(fromOffsets: offsets, toOffset: destination)
        context.preferences.setFavorites(ids)
        revision.bump()
    }

    /// Moves one favorite up or down by one place, for the keyboard.
    func moveFavorite(_ id: ItemID, by offset: Int) {
        var ids = context.preferences.favorites
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        context.preferences.setFavorites(ids)
        revision.bump()
    }

    func removeFavorite(_ id: ItemID) {
        context.preferences.setFavorites(context.preferences.favorites.filter { $0 != id })
        revision.bump()
    }

    // MARK: Typed query

    var inlineCompletion: Bool {
        get { read(HostSettings.inlineCompletion) }
        set { write(HostSettings.inlineCompletion, newValue) }
    }

    /// A fallback as the pane lists it: the command, and whether it shows under the results.
    struct Fallback: Identifiable, Hashable {
        var item: Item
        var isOn: Bool
        var id: ItemID { item.id }
    }

    /// Every fallback of a feature that is on, in the user's order, each with its switch. Root
    /// search reads the same list, so the pane always shows what root search does.
    var fallbacks: [Fallback] {
        revision.track()
        return context.directory.fallbacks(context.preferences.fallbackChoices).map {
            Fallback(item: item($0.id), isOn: $0.isOn)
        }
    }

    /// Turns one fallback on or off.
    func setFallback(_ id: ItemID, isOn: Bool) {
        context.preferences.setFallback(id, isOn: isOn)
        revision.bump()
    }

    func moveFallbacks(from offsets: IndexSet, to destination: Int) {
        var ids = fallbacks.map(\.id)
        ids.reorder(fromOffsets: offsets, toOffset: destination)
        context.preferences.setFallbackOrder(ids)
        revision.bump()
    }

    /// Moves one fallback up or down by one place, for the keyboard.
    func moveFallback(_ id: ItemID, by offset: Int) {
        var ids = fallbacks.map(\.id)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        context.preferences.setFallbackOrder(ids)
        revision.bump()
    }

    /// The command Tab runs with the typed text, or nil.
    var tabCommand: ItemID? {
        get { ItemID(rawValue: read(HostSettings.tabCommand)) }
        set { write(HostSettings.tabCommand, newValue?.rawValue ?? "") }
    }

    /// Commands that take the typed text on Tab, with the current choice even when it no longer
    /// qualifies.
    var tabCandidates: [Item] {
        var items = commands { $0.command.takesRootQueryOnTab }
        if let current = tabCommand, !items.contains(where: { $0.id == current }) { items.append(item(current)) }
        return items
    }

    // MARK: Items

    private func commands(where include: (CommandEntry) -> Bool) -> [Item] {
        revision.track()
        return context.directory.features.flatMap(\.commands).filter(include).map { item($0.id) }
    }

    private func item(_ id: ItemID) -> Item {
        let command = context.directory.command(id)
        let available = id.namespace != ItemID.ReservedNamespace.command || (command?.isEnabled ?? false)
        return Item(id: id, title: context.title(for: id), icon: context.icon(for: id), isAvailable: available)
    }
}
