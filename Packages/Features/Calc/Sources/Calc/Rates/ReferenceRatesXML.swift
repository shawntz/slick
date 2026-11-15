import Foundation

/// Reads the European Central Bank's daily reference rates, published as XML:
///
/// ```xml
/// <gesmes:Envelope xmlns:gesmes="..." xmlns="...">
///   <Cube>
///     <Cube time="2026-11-13">
///       <Cube currency="USD" rate="1.0812"/>
///       ...
/// ```
///
/// Only the first day is read, so the bank's 90-day file works too. Foundation's parser does not
/// load external entities, so the file cannot make it read anything else.
nonisolated enum ReferenceRatesXML {
    /// Why a response is not a rate table.
    enum Problem: Error, Hashable, Sendable {
        case notXML
        case noDay
        case table(RateTable.Problem)
    }

    /// The table in `data`, stamped with when it was downloaded. Rates that are not numbers are
    /// left out; the table must still pass ``RateTable/validate()``.
    static func parse(_ data: Data, downloadedAt: Date) throws(Problem) -> RateTable {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        let finished = parser.parse()
        // The reader stops the parser itself after the first day, which reads as an error.
        guard finished || reader.isDone else { throw .notXML }
        guard let day = reader.day else { throw .noDay }
        let table = RateTable(base: "EUR", day: day, downloadedAt: downloadedAt, rates: reader.rates)
        do {
            try table.validate()
        } catch {
            throw .table(error)
        }
        return table.cleaned
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var day: String?
        var rates: [String: Double] = [:]
        var isDone = false
        private var depthInDay = 0

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes: [String: String] = [:]
        ) {
            guard elementName == "Cube" else { return }
            if let time = attributes["time"] {
                if day != nil {
                    // A second day: the first is complete.
                    isDone = true
                    parser.abortParsing()
                    return
                }
                day = time
                depthInDay = 1
                return
            }
            guard depthInDay > 0 else { return }
            depthInDay += 1
            if let code = attributes["currency"], let text = attributes["rate"], let rate = Double(text) {
                rates[code] = rate
            }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
        ) {
            guard elementName == "Cube", depthInDay > 0 else { return }
            depthInDay -= 1
            if depthInDay == 0 {
                isDone = true
                parser.abortParsing()
            }
        }
    }
}
