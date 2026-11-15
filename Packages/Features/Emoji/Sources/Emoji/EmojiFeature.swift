import Kit

/// Emoji and symbols: a grid in groups with Recently Used first, a default skin tone, paste as the
/// primary action, and ":name" in root search.
public final class EmojiFeature: Feature {
    public static let manifest = FeatureManifest(
        id: "emoji", name: EmojiStrings.featureName, icon: .glyph("😀"), summary: EmojiStrings.summary,
        permissions: [PermissionNeed(.accessibility, reason: EmojiStrings.accessibilityReason)])

    let library: EmojiLibrary
    let grid: EmojiGrid
    let colonSearch: ColonSearch

    public init(context: FeatureContext) {
        library = EmojiLibrary(context: context)
        grid = EmojiGrid(library: library)
        colonSearch = ColonSearch(library: library)
    }

    public var commands: [Command] {
        [
            Command(
                id: "search", title: EmojiStrings.searchCommand, icon: Self.manifest.icon,
                keywords: EmojiStrings.searchKeywords
            ) { [grid] _ in
                .push(.grid(grid.page()))
            }
        ]
    }

    public var liveProviders: [LiveProvider] {
        [.instant(colonSearch)]
    }

    public var settingsPane: SettingsPane? {
        EmojiSettings.pane { [library] context in
            library.clearRecents()
            context.showToast(.success(EmojiStrings.clearedRecents))
        }
    }

    /// Loads the data and builds the colon index off the main thread, and returns at once.
    public func activate() async {
        library.startLoading()
    }

    /// Waits until the data is loaded, for tests and benchmarks.
    func waitUntilLoaded() async {
        _ = await library.loaded()
    }
}
