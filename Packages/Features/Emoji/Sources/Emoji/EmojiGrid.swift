import Kit

/// The Search Emoji and Symbols grid. The host filters it: every row loads once, and the host
/// matches names and keywords as the user types.
final class EmojiGrid: ListSource {
    /// The dropdown option for every group.
    static let allGroupsID = "all"

    private let library: EmojiLibrary

    init(library: EmojiLibrary) {
        self.library = library
    }

    /// An open grid follows the default skin tone, the symbols switch, the recents count and pins.
    var reloadsOnSettings: [AnySettingKey] {
        [
            EmojiSettings.skinTone.erased, EmojiSettings.includeSymbols.erased, EmojiSettings.recentCount.erased,
            EmojiSettings.pinned.erased,
        ]
    }

    /// The page the search command pushes.
    func page(initialQuery: String = "") -> GridPage {
        GridPage(
            self, title: EmojiStrings.pageTitle, searchPlaceholder: EmojiStrings.searchPlaceholder,
            filter: Self.filter(includesSymbols: library.context.settings[EmojiSettings.includeSymbols]), columns: 8,
            showsTitles: false,
            emptyState: EmptyState(
                icon: .symbol("magnifyingglass"), title: EmojiStrings.noMatchesTitle,
                message: EmojiStrings.noMatchesMessage),
            initialQuery: initialQuery)
    }

    /// The category dropdown: every group, or one.
    static func filter(includesSymbols: Bool) -> FilterDropdown {
        let groups = EmojiGroup.allCases.filter { includesSymbols || $0.isEmoji }
        let options = groups.map { group in
            FilterOption(
                id: group.id, title: EmojiStrings.groupTitle(group),
                section: group.isEmoji ? EmojiStrings.emojiFilterSection : EmojiStrings.symbolsFilterSection)
        }
        return FilterDropdown(
            title: EmojiStrings.categoryFilter,
            options: [FilterOption(id: allGroupsID, title: EmojiStrings.allCategories)] + options,
            defaultID: allGroupsID, remembersSelection: false)
    }

    func load(_ request: ListRequest) async throws -> ListResult {
        guard let catalog = await library.loaded() else { throw ActionFailure(EmojiStrings.dataUnreadable) }
        let settings = library.context.settings
        let usage = library.context.usage
        let includeSymbols = settings[EmojiSettings.includeSymbols]
        let limit = min(max(settings[EmojiSettings.recentCount], 0), EmojiSettings.recentCountRange.upperBound)
        let options = EmojiRows.Options(
            tone: settings[EmojiSettings.skinTone], includeSymbols: includeSymbols,
            group: request.filter.flatMap(EmojiGroup.init(id:)),
            recentKeys: limit > 0
                ? usage.recentlyUsed(namespace: EmojiLibrary.namespace, limit: limit).map(\.id.key) : [],
            frecency: usage.frecency(namespace: EmojiLibrary.namespace),
            pinnedKeys: settings[EmojiSettings.pinned])
        let sections = await EmojiRows.sections(catalog, options)
        return ListResult(sections: sections, filter: Self.filter(includesSymbols: includeSymbols))
    }

    func actions(for row: Row) -> [Action] {
        library.actions(for: row)
    }
}
