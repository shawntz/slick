import Foundation
import Kit
import KitHosting
import Observation

/// The root search pane: suggestions, favorites, inline completion, the fallback list and the Tab
/// command.
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

    /// The fallback list in order.
    var fallbacks: [Item] {
        read(HostSettings.fallbackCommands).compactMap { ItemID(rawValue: $0) }.map(item)
    }

    /// Commands that can be fallbacks and are not in the list yet.
    var fallbackCandidates: [Item] {
        let listed = Set(read(HostSettings.fallbackCommands))
        return commands { $0.command.fallback != nil }.filter { !listed.contains($0.id.rawValue) }
    }

    func addFallback(_ id: ItemID) {
        var ids = general[HostSettings.fallbackCommands]
        guard !ids.contains(id.rawValue) else { return }
        ids.append(id.rawValue)
        write(HostSettings.fallbackCommands, ids)
    }

    func removeFallback(_ id: ItemID) {
        write(HostSettings.fallbackCommands, general[HostSettings.fallbackCommands].filter { $0 != id.rawValue })
    }

    func moveFallbacks(from offsets: IndexSet, to destination: Int) {
        var ids = general[HostSettings.fallbackCommands]
        ids.reorder(fromOffsets: offsets, toOffset: destination)
        write(HostSettings.fallbackCommands, ids)
    }

    func moveFallback(_ id: ItemID, by offset: Int) {
        var ids = general[HostSettings.fallbackCommands]
        guard let index = ids.firstIndex(of: id.rawValue), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        write(HostSettings.fallbackCommands, ids)
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
