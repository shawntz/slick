import Kit

extension EmojiLibrary {
    /// The actions for a row from the grid or the colon search, built from the row's key. Pasting
    /// and copying the emoji record a use, which fills Recently Used.
    func actions(for row: Row) -> [Action] {
        guard let entry = catalog?.entry(forKey: row.id.key) else { return fallbackActions(for: row) }
        let glyph = entry.glyph(in: tone)
        let paste = Action.paste(glyph, title: EmojiStrings.paste(entry.name)).recordingUse()
        let copy = Action.copy(glyph, title: EmojiStrings.copy(entry.name), hud: EmojiStrings.copied(glyph))
            .recordingUse()
        var actions = context.settings[EmojiSettings.returnAction] == .paste ? [paste, copy] : [copy, paste]
        if entry.skinTones != .none {
            actions += [skinToneMenu(entry, pastes: true), skinToneMenu(entry, pastes: false)]
        }
        actions.append(pinAction(entry, glyph: glyph))
        actions += [
            Action.copy(entry.name, title: EmojiStrings.copyName, hud: EmojiStrings.copiedName, shortcut: .copy)
                .with(id: "copy-name"),
            Action.copy(
                EmojiEntry.codePoints(of: glyph), title: EmojiStrings.copyCodePoints,
                hud: EmojiStrings.copiedCodePoints, shortcut: Self.copyCodePointsShortcut
            )
            .with(id: "copy-code-points"),
        ]
        return actions
    }

    static let pasteWithToneShortcut = KeyCombo(.v, [.option, .command])
    static let copyWithToneShortcut = KeyCombo(.c, [.option, .command])
    static let copyCodePointsShortcut = KeyCombo(.c, [.option, .shift, .command])

    /// One choice in a skin tone submenu.
    struct ToneChoice: Hashable {
        let id: String
        let title: String
        let glyph: String
        let section: String?
    }

    /// The skin tones offered for one emoji: the default yellow, the five tones, and for two people
    /// every mix of two tones.
    static func toneChoices(_ entry: EmojiEntry) -> [ToneChoice] {
        var choices = SkinTone.allCases.map { tone in
            ToneChoice(
                id: "tone." + tone.rawValue, title: EmojiStrings.toneTitle(tone), glyph: entry.glyph(in: tone),
                section: nil)
        }
        if entry.skinTones == .twoPeople {
            for first in SkinTone.tones {
                for second in SkinTone.tones where second != first {
                    choices.append(
                        ToneChoice(
                            id: "tone." + first.rawValue + "." + second.rawValue,
                            title: EmojiStrings.toneTitle(first, second), glyph: entry.glyph(in: first, second),
                            section: EmojiStrings.twoSkinTones))
                }
            }
        }
        return choices
    }

    /// A submenu that pastes or copies the emoji in a skin tone picked for this one use.
    private func skinToneMenu(_ entry: EmojiEntry, pastes: Bool) -> Action {
        let title = pastes ? EmojiStrings.pasteWithSkinTone : EmojiStrings.copyWithSkinTone
        let id = pastes ? "paste-with-skin-tone" : "copy-with-skin-tone"
        let shortcut = pastes ? Self.pasteWithToneShortcut : Self.copyWithToneShortcut
        return Action.submenu(title, id: id, icon: .glyph(entry.glyph(in: .medium)), shortcut: shortcut) { _ in
            Self.toneChoices(entry).map { choice in
                var action =
                    pastes
                    ? Action.paste(choice.glyph, title: choice.title)
                    : Action.copy(choice.glyph, title: choice.title, hud: EmojiStrings.copied(choice.glyph))
                action.icon = .glyph(choice.glyph)
                return action.with(id: choice.id).with(section: choice.section)
            }
        }
        .recordingUse()
    }

    /// Pins the item to the top of the grid, or unpins it. The open grid follows the setting.
    private func pinAction(_ entry: EmojiEntry, glyph: String) -> Action {
        let key = entry.key
        let settings = context.settings
        let isPinned = settings[EmojiSettings.pinned].contains(key)
        return Action(
            isPinned ? EmojiStrings.unpin : EmojiStrings.pin, id: isPinned ? "unpin" : "pin",
            icon: .symbol(isPinned ? "pin.slash" : "pin"), shortcut: .pin
        ) { context in
            var pins = settings[EmojiSettings.pinned]
            if pins.contains(key) {
                pins.removeAll { $0 == key }
                context.showToast(.success(EmojiStrings.unpinnedToast(glyph)))
            } else {
                pins.append(key)
                context.showToast(.success(EmojiStrings.pinnedToast(glyph)))
            }
            settings[EmojiSettings.pinned] = pins
            return .keepOpen
        }
    }

    /// Paste and copy from the row alone, for a row whose entry is not in the catalog, such as one
    /// root kept from before the data changed.
    private func fallbackActions(for row: Row) -> [Action] {
        guard let glyph = row.payload?.string else { return [] }
        return [
            Action.paste(glyph, title: EmojiStrings.paste(row.title)),
            Action.copy(glyph, title: EmojiStrings.copy(row.title), hud: EmojiStrings.copied(glyph)),
        ]
    }
}
