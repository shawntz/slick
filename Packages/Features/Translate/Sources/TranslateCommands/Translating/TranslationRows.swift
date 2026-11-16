import Foundation
import Kit

/// What a row stands for, carried in its payload, so its actions can be made from the row alone.
nonisolated struct TranslationRow: Codable, Hashable, Sendable {
    /// The text as it was given.
    var original: String
    /// The language the user asked for, typed after "to" or picked in the menu.
    var requested: LanguageTag?
    /// What came of it. Nil while the translation is on its way.
    var outcome: TranslationOutcome?
}

/// A finished request, ready to show: its row and its detail, both built off the main thread.
nonisolated struct Presented: Sendable {
    let outcome: TranslationOutcome
    let row: Row
    let detail: Detail
}

/// Where a row shows, which changes only what a text that is too long says.
nonisolated enum RowPlace: Hashable, Sendable {
    case page
    case root
}

/// The rows and details the feature shows, in its page and in root search. Pure.
///
/// Every row is an answer to one request, so root search remembers none of them.
nonisolated enum TranslationRows {
    static let namespace = "translate"

    static let icon = Icon.symbol("translate")
    static let downloadIcon = Icon.symbol("arrow.down.circle")
    static let problemIcon = Icon.symbol("exclamationmark.triangle")
    static let sameLanguageIcon = Icon.symbol("character.bubble")

    /// The one row of the Translate page.
    static let pageRowID = ItemID(namespace, "translation")
    /// The one row root search shows for the keyword.
    static let rootRowID = ItemID(namespace, "answer")

    /// The row and detail for an outcome. Builds titles from text of any length, so call it off
    /// the main thread.
    @concurrent static func present(
        _ outcome: TranslationOutcome, original: String, requested: LanguageTag?, catalog: LanguageCatalog,
        place: RowPlace
    ) async -> Presented {
        let id = place == .page ? pageRowID : rootRowID
        return Presented(
            outcome: outcome,
            row: row(outcome, original: original, requested: requested, catalog: catalog, id: id, place: place),
            detail: detail(outcome, catalog: catalog))
    }

    /// The row while the translation is on its way.
    static func loadingRow(original: String, requested: LanguageTag?, id: ItemID) -> Row {
        Row(
            id: id, title: TranslateStrings.translating,
            subtitle: TranslationText.title(String(original.prefix(TranslationText.titleLimit + 1))), icon: icon,
            payload: Payload(TranslationRow(original: original, requested: requested, outcome: nil)), memory: .never)
    }

    static func row(
        _ outcome: TranslationOutcome, original: String, requested: LanguageTag?, catalog: LanguageCatalog, id: ItemID,
        place: RowPlace
    ) -> Row {
        let (title, subtitle, icon) = text(outcome, catalog: catalog, place: place)
        var row = Row(
            id: id, title: title, subtitle: subtitle, icon: icon,
            payload: Payload(TranslationRow(original: original, requested: requested, outcome: outcome)),
            memory: .never)
        if let translation = outcome.translation { row.represents = .text(translation) }
        return row
    }

    /// A row's title, subtitle and icon.
    static func text(_ outcome: TranslationOutcome, catalog: LanguageCatalog, place: RowPlace) -> (String, String, Icon)
    {
        switch outcome {
        case .translated(let source, let target, let text):
            return (
                TranslationText.title(text),
                TranslateStrings.direction(from: catalog.title(of: source), to: catalog.title(of: target)), icon
            )
        case .needsDownload(_, _, let missing):
            let names = missing.map(catalog.title(of:))
            return (TranslateStrings.downloadTitle(names), TranslateStrings.notInstalledMessage(names), downloadIcon)
        case .unsupportedLanguage(let identifier):
            let name = catalog.title(ofRecognized: identifier)
            return (
                TranslateStrings.unsupportedLanguageTitle(name), TranslateStrings.unsupportedLanguageMessage(name),
                problemIcon
            )
        case .unsupportedPair(let source, let target):
            let (from, into) = (catalog.title(of: source), catalog.title(of: target))
            return (
                TranslateStrings.unsupportedPairTitle(from, into), TranslateStrings.unsupportedPairMessage(from, into),
                problemIcon
            )
        case .alreadyIn(let target):
            return (
                TranslateStrings.alreadyInTitle(catalog.title(of: target)), TranslateStrings.alreadyInMessage,
                sameLanguageIcon
            )
        case .notRecognized:
            return (TranslateStrings.notRecognizedTitle, TranslateStrings.notRecognizedMessage, problemIcon)
        case .tooLong:
            let message = place == .root ? TranslateStrings.rootTooLongMessage : TranslateStrings.tooLongMessage
            return (TranslateStrings.tooLongTitle, message, problemIcon)
        case .unavailable:
            return (TranslateStrings.unavailableTitle, TranslateStrings.unavailableMessage, problemIcon)
        case .failed(let message):
            return (TranslateStrings.failedTitle, TranslationText.title(message), problemIcon)
        }
    }

    /// The detail beside the page's row: the translation large, with the recognized language
    /// above it, or what went wrong and what to do.
    static func detail(_ outcome: TranslationOutcome, catalog: LanguageCatalog) -> Detail {
        switch outcome {
        case .translated(let source, let target, let text):
            let line = TranslateStrings.detectedLine(catalog.title(of: source), catalog.title(of: target))
            return .markdown(TranslationText.paragraph(line) + "\n\n" + TranslationText.markdown(text))
        case .needsDownload(_, _, let missing):
            let names = missing.map(catalog.title(of:))
            return .markdown(
                "## " + TranslationText.escaped(TranslateStrings.downloadTitle(names)) + "\n\n"
                    + TranslationText.paragraph(TranslateStrings.notInstalledMessage(names)) + "\n\n"
                    + TranslationText.paragraph(TranslateStrings.downloadSteps))
        default:
            let (title, message, _) = text(outcome, catalog: catalog, place: .page)
            return .markdown("## " + TranslationText.escaped(title) + "\n\n" + TranslationText.paragraph(message))
        }
    }
}
