import Kit
import os

/// The feature's state: the catalog and the colon index once they are loaded, and the actions for
/// every row the feature makes. Lives on the main actor; the loading runs off it.
final class EmojiLibrary {
    /// The namespace of every row, in the grid and in root search. `nonisolated` so the background
    /// row builder can read it.
    nonisolated static let namespace = "emoji"

    /// The data and its index, made together off the main thread.
    struct Loaded: Sendable {
        let catalog: EmojiCatalog
        let index: ColonIndex
    }

    let context: FeatureContext
    private(set) var catalog: EmojiCatalog?
    private(set) var colonIndex: ColonIndex?
    private var loading: Task<Loaded?, Never>?

    init(context: FeatureContext) {
        self.context = context
    }

    var tone: SkinTone { context.settings[EmojiSettings.skinTone] }

    /// Starts loading the data off the main thread, once.
    func startLoading() {
        _ = loadTask()
    }

    /// The catalog, after the load finished. Nil only when the data could not be read.
    func loaded() async -> EmojiCatalog? {
        if let catalog { return catalog }
        return await loadTask().value?.catalog
    }

    private func loadTask() -> Task<Loaded?, Never> {
        if let loading { return loading }
        let log = context.log
        let task = Task { [weak self] () -> Loaded? in
            do {
                let loaded = try await Self.load()
                self?.catalog = loaded.catalog
                self?.colonIndex = loaded.index
                return loaded
            } catch {
                log.error("Could not read the emoji data: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        loading = task
        return task
    }

    /// Parses the data and builds the colon index.
    @concurrent nonisolated static func load() async throws -> Loaded {
        let catalog = try EmojiCatalog.parse(EmojiData.text)
        return Loaded(catalog: catalog, index: ColonIndex(catalog: catalog))
    }

    /// Forgets every recently used emoji and symbol.
    func clearRecents() {
        context.usage.forgetAll(namespace: Self.namespace)
    }
}
