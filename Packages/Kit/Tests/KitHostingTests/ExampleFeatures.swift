import Foundation
import Kit

/// A small feature with two commands, a catalog source, an instant provider and a preset, for the
/// directory and preference fakes.
final class ShelfFeature: Feature {
    static let manifest = FeatureManifest(id: "shelf", name: "Shelf", icon: .symbol("books.vertical"))

    let catalog = ShelfCatalog()
    let answers = ShelfAnswers()
    /// Commands the next read of ``commands`` returns, so a test can change the declarations.
    var commandIDs = ["add", "browse"]
    private(set) var activations = 0
    private(set) var deactivations = 0

    init(context: FeatureContext) {}

    var commands: [Command] {
        commandIDs.map { id in Command(id: id, title: "Shelf " + id.capitalized) { _ in .close() } }
    }

    var catalogSources: [any CatalogSource] { [catalog] }
    var liveProviders: [LiveProvider] { [.instant(answers)] }
    var hotkeyPresets: [HotkeyPreset] {
        [HotkeyPreset(id: "default", name: "Default", bindings: ["add": KeyCombo(.a, [.command, .option])])]
    }

    func activate() async { activations += 1 }
    func deactivate() async { deactivations += 1 }
}

final class ShelfCatalog: CatalogSource {
    let namespace = "shelf"

    func rows() async throws -> [Row] {
        [Row(id: ItemID(namespace, "1"), title: "Example Book")]
    }

    func actions(for row: Row) -> [Action] {
        [Action("Open") { _ in .close() }]
    }
}

final class ShelfAnswers: InstantProvider {
    let namespace = "shelf-count"

    func answer(for query: String) -> InstantAnswer? { nil }
    func actions(for row: Row) -> [Action] { [] }
}

/// A feature that is off until the user turns it on.
final class WatcherFeature: Feature {
    static let manifest = FeatureManifest(
        id: "watcher", name: "Watcher", icon: .symbol("eye"), isEnabledByDefault: false)

    init(context: FeatureContext) {}

    var commands: [Command] {
        [Command(id: "start", title: "Start Watching") { _ in .close() }]
    }
}
