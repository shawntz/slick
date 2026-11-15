import Foundation

/// The isolated lookup service for scenarios, self-tests and benchmarks: a few entries and
/// spellings written by hand in the shape the system's text has. It touches nothing on the Mac.
nonisolated final class FixtureLookup: LookupService {
    let definitions: [String: String]
    let spellings: [String: Spelling]

    init(
        definitions: [String: String] = FixtureLookup.sampleDefinitions,
        spellings: [String: Spelling] = FixtureLookup.sampleSpellings
    ) {
        self.definitions = definitions
        self.spellings = spellings
    }

    @concurrent func definitionText(for term: String) async throws -> String? {
        try Task.checkCancellation()
        return definitions[term] ?? definitions[term.lowercased()]
    }

    /// The fixture's verdict, or else correct for a word with an entry and misspelled for any
    /// other word, with no guesses.
    @concurrent func spelling(of word: String) async throws -> Spelling {
        try Task.checkCancellation()
        if let spelling = spellings[word] ?? spellings[word.lowercased()] { return spelling }
        return Spelling(definitions[word.lowercased()] == nil ? .misspelled : .correct)
    }

    // MARK: Samples

    static let lantern = """
        lantern lan·tern | ˈlantərn | noun 1 a lamp in a case with clear sides that keeps the wind \
        from the flame: she carried a lantern down the path. • the glazed room at the top of a \
        lighthouse that holds the lamp. 2 a small open turret on a roof or dome that lets in light \
        or air. ORIGIN Middle English, through Old French from Latin lanterna.
        """

    static let harbor = """
        harbor har·bor | ˈhärbər | (British English harbour) noun a sheltered stretch of water where \
        ships can stay safely: the boats sat out the winter in the harbor. verb [with object] 1 keep \
        (a thought or feeling) in mind for a long time: he harbored a wish to sail. 2 give shelter \
        to: the cove harbored a few small boats. ORIGIN Old English, in the sense ‘shelter’.
        """

    static let iceCream = """
        ice cream | ˌīs ˈkrēm | noun a frozen sweet food made from cream or milk with sugar and \
        flavoring. • a single serving of this food, often in a cone.
        """

    static let naive = """
        naive na·ive | näˈēv | (also naïve) adjective lacking experience of the world and trusting \
        too easily: a naive question. • (of art) simple and direct in style, often by an artist \
        without formal training. DERIVATIVES naively adverb ORIGIN from French, ‘natural’.
        """

    static let cat = "ねこ【猫】 ネコ科の小形の哺乳類。古くから人に飼われ、ねずみを捕る。"

    static let sampleDefinitions: [String: String] = [
        "lantern": lantern, "lanterns": lantern, "harbor": harbor, "harbour": harbor, "ice cream": iceCream,
        "naive": naive, "naïve": naive, "猫": cat,
    ]

    static let sampleSpellings: [String: Spelling] = [
        "recieve": Spelling(.misspelled, guesses: ["receive", "relieve"]),
        "lantren": Spelling(.misspelled, guesses: ["lantern", "lanterns"]),
        "harbour": Spelling(.correct, guesses: ["harbor", "harbours"]),
        "lantern": Spelling(.correct, guesses: ["lanterns", "lantern's"]),
        "xqzzv": Spelling(.misspelled),
        "приветт": Spelling(.misspelled, guesses: ["привет", "привета"]),
        "日本語": Spelling(.unchecked),
    ]
}
