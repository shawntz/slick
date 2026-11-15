import Kit

/// The feature's pane in the settings window.
enum CalcSettingsPane {
    static func pane(history: CalcHistory) -> SettingsPane {
        SettingsPane([
            SettingsSection(
                CalcStrings.answersSection,
                items: [
                    .picker(
                        CalcStrings.decimalPlaces, key: CalcSettings.decimalPlaces, info: CalcStrings.decimalPlacesInfo,
                        titles: CalcStrings.decimalPlacesOption),
                    .picker(
                        CalcStrings.grouping, key: CalcSettings.grouping, info: CalcStrings.groupingInfo,
                        titles: CalcStrings.groupingOption),
                    .picker(
                        CalcStrings.decimalMark, key: CalcSettings.decimalMark, info: CalcStrings.decimalMarkInfo,
                        titles: CalcStrings.decimalMarkOption),
                    .picker(CalcStrings.dateOrder, key: CalcSettings.dateOrder, titles: CalcStrings.dateOrderOption),
                    .picker(CalcStrings.clock, key: CalcSettings.clock, titles: CalcStrings.clockOption),
                    .picker(
                        CalcStrings.angles, key: CalcSettings.angles, info: CalcStrings.anglesInfo,
                        titles: CalcStrings.anglesOption),
                    .picker(
                        CalcStrings.dollar, key: CalcSettings.dollar, info: CalcStrings.dollarInfo,
                        titles: CalcStrings.dollarOption),
                ]),
            SettingsSection(
                CalcStrings.historySection, footer: CalcStrings.historyFooter(appName: Brand.name),
                items: [
                    .toggle(
                        CalcStrings.keepsHistory, key: CalcSettings.keepsHistory, info: CalcStrings.keepsHistoryInfo),
                    .picker(
                        CalcStrings.historyLimit, key: CalcSettings.historyLimit,
                        options: CalcSettings.historyLimits.map { ($0, CalcStrings.historyLimitOption($0)) },
                        info: CalcStrings.historyLimitInfo, confirm: limitConfirmation),
                    .button(
                        CalcStrings.clearHistory, style: .destructive, confirmation: CalcActions.clearConfirmation
                    ) { context in
                        await history.clear()
                        context.showToast(.success(CalcStrings.clearedToast))
                    },
                ]),
            SettingsSection(
                CalcStrings.ratesSection, footer: CalcStrings.ratesFooter,
                items: [
                    .toggle(
                        CalcStrings.downloadsRates, key: CalcSettings.downloadsRates,
                        info: CalcStrings.downloadsRatesInfo)
                ]),
        ])
    }

    /// Asks before a smaller history size, which deletes the oldest answers at once. A larger size
    /// loses nothing and asks nothing.
    static func limitConfirmation(stored: Int, chosen: Int) -> Confirmation? {
        let range = CalcSettings.historyLimitRange
        let current = min(max(stored, range.lowerBound), range.upperBound)
        guard chosen < current else { return nil }
        return Confirmation(
            CalcStrings.limitQuestion(chosen), message: CalcStrings.limitMessage(chosen),
            confirmTitle: CalcStrings.limitConfirm, isDestructive: true)
    }
}
