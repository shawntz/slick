import Foundation
import Kit

/// The Color History page: swatches with Pinned first, then by day, newest first, filtered by the
/// host, with a detail pane that shows the color large, every format and its contrast.
final class HistoryList: ListSource {
    private let history: ColorHistory
    private let actionsMaker: ColorActions
    private let settings: FeatureSettings
    private let clock: any ClockService

    init(history: ColorHistory, actions: ColorActions, context: FeatureContext) {
        self.history = history
        self.actionsMaker = actions
        self.settings = context.settings
        self.clock = context.clock
    }

    var changes: ChangeSignal? { history.changes }

    /// Titles and subtitles follow the default format and the hex case.
    var reloadsOnSettings: [AnySettingKey] {
        [ColorSettings.defaultFormat.erased, ColorSettings.hexCase.erased]
    }

    func page() -> Page {
        .list(
            ListPage(
                self, title: ColorStrings.historyCommand, searchPlaceholder: ColorStrings.historyPlaceholder,
                showsDetail: true, emptyState: emptyState()))
    }

    func load(_ request: ListRequest) async throws -> ListResult {
        await history.loaded()
        try Task.checkCancellation()
        let sections = await Self.sections(
            history.entries, formatter: actionsMaker.formatter, format: actionsMaker.defaultFormat, clock: clock)
        return ListResult(sections: sections, emptyState: emptyState())
    }

    func actions(for row: Row) -> [Action] {
        actionsMaker.forHistory(row)
    }

    func detail(for row: Row) async throws -> Detail? {
        guard let shown = try? row.payload?.decode(ColorEntry.self) else { return nil }
        let entry = history.entry(shown.id) ?? shown
        return ColorDetail.detail(for: entry, formatter: actionsMaker.formatter)
    }

    private func emptyState() -> EmptyState {
        EmptyState(
            icon: .symbol("swatchpalette"), title: ColorStrings.emptyTitle, message: ColorStrings.emptyMessage,
            actions: [
                .runCommand(ColorActions.pickCommand, title: ColorStrings.pickCommand, icon: .symbol("eyedropper"))
            ])
    }

    /// Pinned, then one section per day. Built off the main thread, since a history may hold a
    /// thousand colors and each row formats its color.
    @concurrent nonisolated static func sections(
        _ entries: [ColorEntry], formatter: ColorFormatter, format: ColorFormat, clock: any ClockService
    ) async -> [ListSection] {
        build(entries, formatter: formatter, format: format, clock: clock)
    }

    /// The same as ``sections(_:formatter:format:clock:)`` on the calling thread.
    nonisolated static func build(
        _ entries: [ColorEntry], formatter: ColorFormatter, format: ColorFormat, clock: any ClockService
    ) -> [ListSection] {
        let pinned = entries.filter(\.isPinned)
        let others = entries.filter { !$0.isPinned }
        var sections: [ListSection] = []
        if !pinned.isEmpty {
            sections.append(
                ListSection(
                    ColorStrings.pinnedSection, id: "pinned",
                    rows: pinned.map { row(for: $0, formatter: formatter, format: format) }))
        }
        let days = DaySections(clock: clock, direction: .past)
        sections += days.sections(others, date: \.date) { row(for: $0, formatter: formatter, format: format) }
        return sections
    }

    /// A color: its name or hex value as the title, the default format as the subtitle, the swatch
    /// as the icon, and when it was added.
    nonisolated static func row(for entry: ColorEntry, formatter: ColorFormatter, format: ColorFormat) -> Row {
        let hex = formatter.hex(entry.color)
        let title = entry.name ?? hex
        let main = formatter.string(entry.color, as: format, name: entry.name)
        let subtitle = main == title ? formatter.string(entry.color, as: .rgb) : main
        var accessories: [Accessory] = []
        if entry.color.isOutsideSRGB { accessories.append(.tag(ColorStrings.outsideSRGB, color: .orange)) }
        accessories.append(.date(entry.date))
        var keywords = [hex, String(hex.dropFirst())]
        if entry.name != nil { keywords.append(main) }
        if let css = CSSNames.name(of: entry.color) { keywords.append(css) }
        return Row(
            id: ItemID(ColorsFeature.namespace, "history." + entry.id.uuidString), title: title, subtitle: subtitle,
            icon: .color(entry.color.kitColor), accessories: accessories, keywords: keywords,
            payload: Payload(entry), memory: .never)
    }
}

/// The detail pane of a color in the history.
nonisolated enum ColorDetail {
    static func detail(for entry: ColorEntry, formatter: ColorFormatter) -> Detail {
        let color = entry.color
        var items: [MetadataItem] = []
        if let name = entry.name { items.append(.label(ColorStrings.nameLabel, value: name)) }
        for format in ColorFormat.allCases {
            items.append(
                .label(ColorStrings.formatTitle(format), value: formatter.string(color, as: format, name: entry.name)))
        }
        if let css = CSSNames.name(of: color) { items.append(.label(ColorStrings.cssNameLabel, value: css)) }
        items.append(.separator)
        items += contrastItems(color, on: .white, label: ColorStrings.contrastOnWhite, tags: ColorStrings.wcagOnWhite)
        items += contrastItems(color, on: .black, label: ColorStrings.contrastOnBlack, tags: ColorStrings.wcagOnBlack)
        items.append(.separator)
        if color.isOutsideSRGB {
            items.append(.label(ColorStrings.gamutLabel, value: ColorStrings.gamutOutside))
            let parts = [color.red, color.green, color.blue].map { Decimals.string($0, places: 4) }
            items.append(.label(ColorStrings.extendedLabel, value: parts.joined(separator: " ")))
        }
        items.append(
            .label(
                ColorStrings.sourceLabel,
                value: entry.source == .picked ? ColorStrings.sourcePicked : ColorStrings.sourceTyped))
        items.append(.date(ColorStrings.addedLabel, entry.date))
        return Detail(.color(color.kitColor), metadata: items)
    }

    /// The ratio of text in the color on a background, and its WCAG levels as tags.
    static func contrastItems(_ color: ColorValue, on background: ColorValue, label: String, tags: String)
        -> [MetadataItem]
    {
        let contrast = Contrast(foreground: color, background: background)
        return [
            .label(label, value: contrast.text),
            .tags(
                tags,
                [
                    Tag(ColorStrings.normalTag(contrast.normalText), color: tagColor(contrast.normalText)),
                    Tag(ColorStrings.largeTag(contrast.largeText), color: tagColor(contrast.largeText)),
                ]),
        ]
    }

    static func tagColor(_ level: WCAGLevel) -> KitColor {
        level == .fail ? .red : .green
    }
}
