import Foundation
import Kit

/// The actions of calculator rows in root search and of history rows. Built from the row's payload
/// alone, so they work for any row the feature made.
final class CalcActions {
    /// Option-Command-C, as other launchers copy an answer without formatting.
    static let copyPlainShortcut = KeyCombo(.c, [.option, .command])
    /// Option-Shift-Command-C.
    static let copyQuestionShortcut = KeyCombo(.c, [.option, .shift, .command])
    /// The history command's root ID.
    static let historyCommand = ItemID.command(feature: CalculatorFeature.featureID, command: "history")

    private let history: CalcHistory
    private let rates: RateKeeper
    private let settings: FeatureSettings

    init(history: CalcHistory, rates: RateKeeper, settings: FeatureSettings) {
        self.history = history
        self.rates = rates
        self.settings = settings
    }

    /// The actions for a row the provider made.
    func forAnswer(_ row: Row) -> [Action] {
        guard let payload = try? row.payload?.decode(AnswerPayload.self) else { return [] }
        switch payload.status {
        case .answer:
            return answerActions(payload)
        case .problem:
            return []
        case .ratesLoading:
            return [ratesAction(CalcStrings.showAnswer, id: "show-answer", question: payload.question)]
        case .ratesUnavailable:
            return [ratesAction(CalcStrings.tryAgain, id: "try-again", question: payload.question)]
        case .ratesOff:
            let settings = self.settings
            return [
                ratesAction(CalcStrings.turnOnRates, id: "turn-on-rates", question: payload.question) {
                    settings[CalcSettings.downloadsRates] = true
                }
            ]
        }
    }

    private func answerActions(_ payload: AnswerPayload) -> [Action] {
        let history = self.history
        let record: @MainActor @Sendable (ActionContext) async throws -> Void = { _ in
            await history.record(
                question: payload.question, answer: payload.answer, plainNumber: payload.plainNumber)
        }
        var actions = [
            Action.copy(payload.answer, title: CalcStrings.copyAnswer, hud: CalcStrings.copied(payload.answer))
                .then(record),
            Action.paste(payload.answer, title: CalcStrings.pasteAnswer, shortcut: .secondaryAction).then(record),
        ]
        if let plain = payload.plainNumber {
            actions.append(
                Action.copy(
                    plain, title: CalcStrings.copyPlainNumber, hud: CalcStrings.copied(plain),
                    shortcut: Self.copyPlainShortcut
                ).with(id: "copy-plain-number").then(record))
        }
        actions.append(
            Action.copy(
                CalcStrings.questionAndAnswer(payload.question, payload.answer),
                title: CalcStrings.copyQuestionAndAnswer, hud: CalcStrings.copiedQuestionAndAnswer,
                shortcut: Self.copyQuestionShortcut
            ).with(id: "copy-question-and-answer").then(record))
        // Its own action rather than `represents`, which would also bring every feature's actions for
        // text, such as Define Word, to a number.
        actions.append(.showInLargeType(payload.answer))
        for (index, form) in payload.forms.enumerated() {
            actions.append(
                Action.copy(form.text, title: CalcStrings.copyForm(form.label), hud: CalcStrings.copied(form.text))
                    .with(id: "copy-form-\(index)").with(section: CalcStrings.otherForms))
        }
        if payload.usesRates == true, rates.isEnabled {
            actions.append(refreshRatesAction(question: payload.question))
        }
        actions.append(historyAction())
        return actions
    }

    /// Opens the history. Hidden while the command is unavailable.
    func historyAction() -> Action {
        .runCommand(Self.historyCommand, title: CalcStrings.openHistory, icon: .symbol("clock.arrow.circlepath"))
    }

    /// Downloads rates because the user asked, then shows the question again in root search so the
    /// answer appears. The setting is read again when the action runs, not when the row was made:
    /// a row from before the user turned downloads off never sends a request.
    private func ratesAction(
        _ title: String, id: String, question: String,
        before: @escaping @MainActor @Sendable () -> Void = {}
    ) -> Action {
        let rates = self.rates
        return Action(title, id: id, icon: .symbol("arrow.clockwise"), runPolicy: .dropWhileRunning) { _ in
            before()
            guard rates.isEnabled else {
                throw ActionFailure(CalcStrings.ratesOffTitle, message: CalcStrings.ratesOffMessage)
            }
            guard await rates.downloadNow() else {
                throw ActionFailure(CalcStrings.ratesFailedTitle, message: CalcStrings.ratesFailedMessage)
            }
            return .showRoot(query: question)
        }
    }

    /// Downloads the bank's rates again now, whatever their age, as other launchers' Refresh
    /// Currencies does, then shows the question again with the new rates. Offered only on answers
    /// that used rates, and only while downloads are on.
    private func refreshRatesAction(question: String) -> Action {
        let rates = self.rates
        return Action(
            CalcStrings.refreshRates, id: "refresh-rates", icon: .symbol("arrow.clockwise"), shortcut: .refresh,
            runPolicy: .dropWhileRunning
        ) { context in
            guard rates.isEnabled else {
                throw ActionFailure(CalcStrings.ratesOffTitle, message: CalcStrings.ratesOffMessage)
            }
            guard await rates.downloadNow() else {
                throw ActionFailure(CalcStrings.ratesFailedTitle, message: CalcStrings.ratesFailedMessage)
            }
            context.showToast(.success(CalcStrings.refreshedRates))
            return .showRoot(query: question)
        }
    }

    /// The actions for a row of the history page.
    func forHistory(_ row: Row) -> [Action] {
        guard let entry = try? row.payload?.decode(HistoryEntry.self) else { return [] }
        let history = self.history
        var actions = [
            Action.copy(entry.answer, title: CalcStrings.copyAnswer, hud: CalcStrings.copied(entry.answer)),
            Action(
                CalcStrings.useAgain, id: "use-again", icon: .symbol("magnifyingglass"), shortcut: .secondaryAction
            ) { _ in
                .showRoot(query: entry.question)
            },
            Action.paste(entry.answer, title: CalcStrings.pasteAnswer),
        ]
        if let plain = entry.plainNumber {
            actions.append(
                Action.copy(
                    plain, title: CalcStrings.copyPlainNumber, hud: CalcStrings.copied(plain),
                    shortcut: Self.copyPlainShortcut
                ).with(id: "copy-plain-number"))
        }
        actions.append(
            Action.copy(
                CalcStrings.questionAndAnswer(entry.question, entry.answer), title: CalcStrings.copyQuestionAndAnswer,
                hud: CalcStrings.copiedQuestionAndAnswer, shortcut: Self.copyQuestionShortcut
            ).with(id: "copy-question-and-answer"))
        actions.append(
            Action(
                CalcStrings.deleteEntry, id: "delete", icon: .symbol("trash"), shortcut: .remove, style: .destructive,
                confirmation: Confirmation(
                    CalcStrings.deleteQuestion(entry.question), message: CalcStrings.deleteMessage,
                    confirmTitle: CalcStrings.deleteConfirm, isDestructive: true)
            ) { context in
                await history.delete(entry.id)
                context.showToast(.success(CalcStrings.deletedToast))
                return .keepOpen
            })
        actions.append(clearHistoryAction())
        return actions
    }

    /// Deletes every saved answer after asking.
    func clearHistoryAction() -> Action {
        let history = self.history
        return Action(
            CalcStrings.clearHistory, id: "clear-history", icon: .symbol("trash.slash"), shortcut: .removeAll,
            style: .destructive, confirmation: Self.clearConfirmation
        ) { context in
            await history.clear()
            context.showToast(.success(CalcStrings.clearedToast))
            return .keepOpen
        }
    }

    static let clearConfirmation = Confirmation(
        CalcStrings.clearQuestion, message: CalcStrings.clearMessage, confirmTitle: CalcStrings.clearConfirm,
        isDestructive: true)
}
