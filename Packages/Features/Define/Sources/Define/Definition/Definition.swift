/// One dictionary entry, split into the parts the detail page shows.
///
/// ``DefinitionParser`` makes it from the plain text Dictionary Services returns. That text has no
/// markup, so the parts are found by the shape of the text. When the shape is not one the parser
/// knows, the entry holds the whole text and ``isStructured`` is false.
///
/// The summary, the plain text and the Markdown are made once, when the entry is made. Lookups
/// make entries off the main thread, so a page only hands the finished text to the host.
nonisolated struct Definition: Hashable, Sendable {
    /// What the user looked up, cleaned. It may differ from the headword: "ran" finds "run".
    let term: String
    /// The entry's word or phrase, without syllable marks or a homograph number.
    let headword: String
    /// The headword split into syllables, such as "lan·tern", when the text has it.
    let syllables: String?
    /// The pronunciation in the dictionary's own notation, when the text has one.
    let pronunciation: String?
    /// The body: parts of speech, numbered senses, subsenses and labelled sections, in order.
    let paragraphs: [DefinitionParagraph]
    /// False when the parser found no structure and ``paragraphs`` holds the text whole.
    let isStructured: Bool

    /// The first meaning on one line, for a row's subtitle. Examples after a colon and grammar
    /// notes in brackets are left out. Empty when the entry has no meaning to show.
    let summary: String
    /// The entry as plain text with line breaks, for Copy Definition and Paste Definition.
    let plainText: String
    /// The entry as Markdown for the detail page, with the dictionary's own text escaped.
    let markdown: String

    init(
        term: String, headword: String, syllables: String? = nil, pronunciation: String? = nil,
        paragraphs: [DefinitionParagraph], isStructured: Bool
    ) {
        self.term = term
        self.headword = headword
        self.syllables = syllables
        self.pronunciation = pronunciation
        self.paragraphs = paragraphs
        self.isStructured = isStructured
        summary = DefinitionText.summary(of: paragraphs)
        plainText = DefinitionText.plain(
            headword: headword, syllables: syllables, pronunciation: pronunciation, paragraphs: paragraphs)
        markdown = DefinitionText.markdown(
            headword: headword, syllables: syllables, pronunciation: pronunciation, paragraphs: paragraphs)
    }
}

/// One paragraph of a definition's body.
nonisolated enum DefinitionParagraph: Hashable, Sendable {
    /// A part of speech such as "noun", with the grammar note that comes before its first sense,
    /// such as "[with object]".
    case partOfSpeech(String, note: String?)
    /// A numbered sense.
    case sense(Int, String)
    /// A subsense, which the dictionary marks with a bullet.
    case subsense(String)
    /// A labelled section such as Origin or Phrases. The label is in title case.
    case section(String, String)
    /// Text with no number or label: the only sense of a part of speech, a variant note such as
    /// "(also naïve)", or a whole entry the parser could not split.
    case text(String)
}
