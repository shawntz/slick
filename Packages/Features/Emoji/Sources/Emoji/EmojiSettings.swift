import Kit

/// The feature's settings, stored as `emoji.<name>`.
nonisolated enum EmojiSettings {
    /// The tone applied to every emoji that takes one. Default: the yellow of the system picker.
    static let skinTone = SettingKey("skinTone", default: SkinTone.none)
    /// What Return does. Default: paste, as in the system's emoji picker.
    static let returnAction = SettingKey("returnAction", default: ReturnAction.paste)
    /// Arrows, math, currency and the other symbol sets in the grid.
    static let includeSymbols = SettingKey("includeSymbols", default: true)
    /// ":name" in root search.
    static let colonSearch = SettingKey("colonSearch", default: true)
    /// How many recently used emoji the grid shows first. Two rows of the default grid.
    static let recentCount = SettingKey("recentCount", default: 16)
    /// Keys of the pinned emoji and symbols, in the order they were pinned. They show first in the
    /// grid and rank first among equal matches.
    static let pinned = SettingKey("pinned", default: [String]())

    /// The most recently used emoji the grid can show.
    static let recentCountRange = 0...48
}

/// What Return does to an emoji.
nonisolated enum ReturnAction: String, CaseIterable, Sendable, SettingValue {
    case paste, copy
}

extension EmojiSettings {
    /// The feature's pane in the settings window.
    @MainActor static func pane(clearRecents: @escaping @MainActor @Sendable (ActionContext) async throws -> Void)
        -> SettingsPane
    {
        let sample = EmojiEntry(
            glyph: "✋", name: "", group: .people,
            variants: ["✋🏻", "✋🏼", "✋🏽", "✋🏾", "✋🏿"])
        return SettingsPane([
            SettingsSection(
                EmojiStrings.behaviorSection, footer: EmojiStrings.dataNote(EmojiData.sourceVersion),
                items: [
                    .picker(EmojiStrings.skinTone, key: skinTone, info: EmojiStrings.skinToneInfo) { tone in
                        sample.glyph(in: tone) + "  " + EmojiStrings.toneTitle(tone)
                    },
                    .picker(EmojiStrings.returnAction, key: returnAction) { action in
                        action == .paste ? EmojiStrings.returnPastes : EmojiStrings.returnCopies
                    },
                    .toggle(EmojiStrings.includeSymbols, key: includeSymbols, info: EmojiStrings.includeSymbolsInfo),
                    .toggle(EmojiStrings.colonSearch, key: colonSearch, info: EmojiStrings.colonSearchInfo),
                ]),
            SettingsSection(
                EmojiStrings.recentSection,
                items: [
                    .stepper(
                        EmojiStrings.recentCount, key: recentCount, range: recentCountRange, step: 8,
                        info: EmojiStrings.recentCountInfo),
                    .button(
                        EmojiStrings.clearRecents, style: .destructive,
                        confirmation: Confirmation(
                            EmojiStrings.clearRecentsQuestion, message: EmojiStrings.clearRecentsMessage,
                            confirmTitle: EmojiStrings.clearRecentsConfirm, isDestructive: true),
                        run: clearRecents),
                ]),
        ])
    }
}
