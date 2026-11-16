extension Theme {
    /// Two pieces of neutral glass: a tall capsule for the query, and 10 pt below it a results
    /// container with 36 pt corners and 48 pt rows. White line glyphs and titles, a Command-digit
    /// hint at the end of the first nine rows, a caret with a cool-to-warm glow, a faint rim on
    /// the lower half of each piece and one soft shadow under both. The action bar shows only for
    /// a toast; Command-K still opens the action panel.
    ///
    /// The proportions, type sizes and row rhythm follow a measured reference at 520 pt wide. The
    /// Spotlight theme is 680 pt wide with every other value kept, so a list beside a detail pane
    /// and a grid still have room. The results glass is darker than the reference, whose titles fell to 2:1 over a
    /// white backdrop, so that titles keep 4.5:1 and secondary text 3:1.
    public static let spotlight = Theme(
        panel: PanelMetrics(
            width: 680,
            cornerRadius: 36,
            topFraction: 0.22,
            shadowInsets: ThemeInsets(top: 24, left: 40, bottom: 60, right: 40),
            // Nine two-line rows with their padding, so the last row is never cut.
            maxContentHeight: 560,
            minimumScreenMargin: 8,
            hairlinePixels: 0,
            glassStyle: .regular,
            layout: .split,
            fieldGap: 10,
            fieldCornerRadius: 43.5,
            rimWidth: 1,
            shadowRadius: 20,
            shadowOffset: 18
        ),
        queryRow: QueryRowMetrics(
            height: 87,
            leadingInset: 38,
            glyphSlotWidth: 20,
            glyphSize: 18,
            textGap: 12,
            trailingInset: 38,
            breadcrumbHeight: 30,
            breadcrumbPadding: 11,
            breadcrumbMaxFraction: 0.4,
            showsRootGlyph: false
        ),
        list: ListMetrics(
            rowHeight: 48,
            twoLineRowHeight: 56,
            twoLineGap: 2,
            // A symbol fills about four fifths of its box, so a 28 pt box draws the reference's
            // 19 to 22 pt glyphs. The glyph's centre stays 44 pt in and the title 81 pt in.
            iconSize: 28,
            iconX: 30,
            iconPlaceholderRadius: 7,
            iconTextGap: 23,
            titleSubtitleGap: 10,
            minimumSubtitleWidth: 40,
            trailingInset: 36,
            accessorySpacing: 10,
            maxAccessoryFraction: 0.45,
            accessoryGap: 14,
            accessoryIconSize: 18,
            sectionHeaderHeight: 30,
            sectionHeaderX: 32,
            sectionHeaderBaseline: 21,
            verticalPadding: 11,
            maxVisibleRows: 9,
            tagHeight: 20,
            tagPadding: 8,
            keycapHeight: 22,
            keycapMinWidth: 22,
            keycapPadding: 6,
            keycapRadius: 6,
            keycapSpacing: 3,
            scrollIndicatorWidth: 3,
            scrollIndicatorInset: 6,
            scrollIndicatorLinger: 0.6,
            wheelLineHeight: 24,
            showsRunHints: true
        ),
        // Inset as far as the rows' padding and half as tall as a row, so the lens is a capsule
        // that follows the container's corners.
        lens: LensMetrics(style: .fill, horizontalInset: 11, cornerRadius: 24),
        actionBar: ActionBarMetrics(
            height: 40,
            horizontalInset: 32,
            iconSize: 16,
            itemSpacing: 6,
            dividerSpacing: 10,
            dividerHeight: 16,
            keycapHeight: 20,
            keycapMinWidth: 20,
            keycapPadding: 5,
            keycapRadius: 5,
            keycapSpacing: 3,
            titleMaxFraction: 0.3,
            showsOnlyForToasts: true
        ),
        grid: GridMetrics(
            glyphColumns: 8,
            imageColumns: 5,
            horizontalInset: 24,
            spacing: 10,
            tileCornerRadius: 12,
            imagePadding: 6,
            glyphScale: 0.5,
            titleGap: 6,
            titleHeight: 18,
            subtitleHeight: 15,
            verticalPadding: 14,
            lensCornerRadius: 16,
            lensOutset: 4
        ),
        detail: DetailMetrics(
            // Wider than Standard's share: with the rows' 81 pt indent, the titles beside a detail
            // pane keep as much room as Standard's. That list shows no run hints.
            listFraction: 0.55,
            padding: 20,
            imagePadding: 14,
            lineSpacing: 2,
            paragraphSpacing: 8,
            codeBlockPadding: 8,
            listIndent: 18,
            swatchHeight: 132,
            swatchCornerRadius: 14,
            thumbnailSize: 128,
            metadataRowHeight: 28,
            metadataGroupGap: 6,
            metadataMaxFraction: 0.5
        ),
        card: CardMetrics(
            width: 340,
            confirmWidth: 380,
            menuWidth: 240,
            margin: 11,
            cornerRadius: 24,
            menuCornerRadius: 18,
            filterHeight: 40,
            horizontalPadding: 16,
            verticalPadding: 8,
            rowHeight: 38,
            menuRowHeight: 34,
            iconSize: 18,
            iconGap: 12,
            sectionHeaderHeight: 28,
            sectionHeaderBaseline: 19,
            selectionInset: 6,
            selectionCornerRadius: 12,
            maxVisibleRows: 8,
            dimAlpha: 0.6,
            confirmPadding: 22,
            confirmGap: 12,
            buttonHeight: 32,
            buttonCornerRadius: 16,
            buttonPadding: 14,
            buttonSpacing: 10
        ),
        form: FormMetrics(
            labelWidth: 150,
            labelGap: 14,
            horizontalInset: 32,
            verticalPadding: 20,
            rowSpacing: 12,
            controlHeight: 30,
            multilineHeight: 84,
            fieldCornerRadius: 10,
            fieldPadding: 9,
            focusRingWidth: 2,
            messageGap: 4,
            messageHeight: 17,
            checkboxSize: 16,
            checkboxCornerRadius: 4.5,
            tagHeight: 22,
            tagSpacing: 4,
            separatorHeight: 13
        ),
        chips: ChipMetrics(
            maxArguments: 3,
            height: 32,
            cornerRadius: 16,
            padding: 12,
            spacing: 8,
            minimumWidth: 88,
            maximumWidth: 200,
            chevronSize: 10
        ),
        feedback: FeedbackMetrics(
            emptyStateHeight: 220,
            emptySymbolSize: 40,
            emptyTitleGap: 14,
            emptyHintGap: 4,
            emptyHintWidth: 380,
            loadingBarHeight: 2,
            loadingSegmentFraction: 0.28,
            hudHeight: 40,
            hudPadding: 18,
            hudSymbolSize: 16,
            hudSymbolGap: 8,
            hudBottomMargin: 96,
            hudDuration: 1.2,
            hudShadowInset: 24
        ),
        motion: Theme.standard.motion,
        fonts: ThemeFonts(
            query: ThemeFont(size: 22),
            title: ThemeFont(size: 17, weight: .semibold),
            subtitle: ThemeFont(size: 14),
            accessory: ThemeFont(size: 14),
            sectionHeader: ThemeFont(size: 13, weight: .semibold),
            tag: ThemeFont(size: 12, weight: .medium),
            keycap: ThemeFont(size: 12.5, weight: .medium),
            breadcrumb: ThemeFont(size: 15, weight: .medium),
            actionBar: ThemeFont(size: 13),
            actionBarPrimary: ThemeFont(size: 13, weight: .medium),
            actionBarKeycap: ThemeFont(size: 12, weight: .medium),
            gridTitle: ThemeFont(size: 13, weight: .semibold),
            gridSubtitle: ThemeFont(size: 12),
            detailText: ThemeFont(size: 14),
            detailMonospaced: ThemeFont(size: 13, design: .monospaced),
            markdownHeadings: [
                ThemeFont(size: 19, weight: .semibold), ThemeFont(size: 16.5, weight: .semibold),
                ThemeFont(size: 15, weight: .semibold),
            ],
            metadataLabel: ThemeFont(size: 13),
            metadataValue: ThemeFont(size: 13.5),
            cardFilter: ThemeFont(size: 15),
            cardRow: ThemeFont(size: 15),
            cardSection: ThemeFont(size: 12, weight: .semibold),
            confirmTitle: ThemeFont(size: 17, weight: .semibold),
            confirmMessage: ThemeFont(size: 14),
            button: ThemeFont(size: 14, weight: .medium),
            formLabel: ThemeFont(size: 14),
            formControl: ThemeFont(size: 14),
            formMessage: ThemeFont(size: 13),
            chip: ThemeFont(size: 15),
            emptyTitle: ThemeFont(size: 17, weight: .medium),
            emptyHint: ThemeFont(size: 14),
            hud: ThemeFont(size: 14.5, weight: .medium),
            runHint: ThemeFont(size: 17)
        ),
        light: Theme.standard.light.spotlight(dark: false),
        dark: Theme.standard.dark.spotlight(dark: true),
        clarity: 1
    )

    /// What the settings window says about the Spotlight theme. The one place in the app that says
    /// what it is modeled on.
    static let spotlightSummary =
        "Looks like Spotlight in macOS 27. The search field is a capsule of glass, and the results show in a "
        + "separate panel below it."
}

extension ThemePalette {
    /// Spotlight's neutral colours on Standard's palette. The capsule is darker at its top and the
    /// results glass is tinted toward the appearance's base colour, both neutral.
    fileprivate func spotlight(dark: Bool) -> ThemePalette {
        var palette = self
        let base: ThemeColor.System = dark ? .black : .white
        // The lightest results tint that keeps rule 5 over every test backdrop, so the container
        // stays a lighter grey than the capsule, as in the reference. A sweep of 0.16 to 0.32 in
        // dark mode passed plain rows from 0.28; the selected two-line row over a white page then
        // read 4.3 to 1 and set 0.32. Light mode passed from 0.15 and keeps 0.2 for room. Dimmed
        // titles, keycaps, tags and form messages are relieved below so that they do not set it.
        palette.glassTint = ThemeColor(base, alpha: dark ? 0.32 : 0.2)
        palette.fieldTint = ThemeColor(base, alpha: dark ? 0.2 : 0.35)
        palette.fieldShade = ThemeColor(base, alpha: dark ? 0.95 : 0.5)
        // A faint sheen on the lower edge, not an outline: on the results glass 0.25 still read
        // +62 to +84 against the reference's +26 to +55.
        palette.rim = ThemeColor(.white, alpha: dark ? 0.18 : 0.6)
        palette.shadow = ThemeColor(.black, alpha: dark ? 0.33 : 0.22)
        // Full strength in both tones, as the reference's white titles are.
        palette.title = ThemeColor(dark ? .white : .black)
        palette.unmatchedTitleAlpha = dark ? 0.9 : unmatchedTitleAlpha
        let secondary = dark ? ThemeColor(.white, alpha: 0.72) : ThemeColor(.label, alpha: 0.72)
        palette.subtitle = secondary
        palette.accessory = secondary
        palette.sectionHeader = secondary
        // Dimmer than the subtitles, as the reference's are, and still 3:1 on the results glass.
        palette.runHint = dark ? ThemeColor(.white, alpha: 0.62) : secondary
        // A keycap's own fill lightens the glass under its text, so in dark mode the text is
        // white: at 0.72 it was the cell that set the tint, 2.1 to 2.8 to 1 over a white page.
        palette.keycapText = dark ? ThemeColor(.white) : secondary
        // On the lighter glass a tag's own colour reads at 2.6 to 1, so its text leans further
        // toward white, and so does the error text under a form field.
        if dark {
            palette.tagTextDepth = 0.75
            // Whole steps of 255, so the color survives the 8-bit hex form of theme files.
            palette.error = ThemeColor(red: 1, green: 189 / 255, blue: 184 / 255)
        }
        // Faint, so a white title on it keeps 4.5:1 over a white backdrop.
        palette.lensFill = dark ? ThemeColor(.white, alpha: 0.06) : ThemeColor(.black, alpha: 0.08)
        // Cards sit on the lighter results glass, so they take a deeper tint than Standard's.
        palette.cardTint = dark ? ThemeColor(.black, alpha: 0.72) : cardTint
        palette.caret = ThemeColor(.label)
        // Brightest and near white beside the middle of the caret, fainter and paler toward its
        // tips: sky blue above, amber below.
        palette.caretGlow = [
            ThemeColor(red: 0xA3 / 255, green: 0xDB / 255, blue: 1, alpha: dark ? 0.6 : 0.32),
            ThemeColor(red: 0xE6 / 255, green: 1, blue: 0xD9 / 255, alpha: dark ? 1 : 0.5),
            ThemeColor(red: 1, green: 0xE3 / 255, blue: 0xA6 / 255, alpha: dark ? 0.6 : 0.32),
        ]
        palette.placeholder = ThemeColor(.secondaryLabel)
        palette.emptySymbol = ThemeColor(.label)
        return palette
    }
}

extension Theme {
    /// The Spotlight theme under the name an earlier build gave it.
    @available(*, deprecated, renamed: "spotlight")
    public static var beam: Theme { spotlight }
}
