import Foundation
import KitTemplates

/// The snippets with every lookup the feature needs, built once per change off the main thread.
///
/// It is a plain value, so a background task can hold a snapshot while the library moves on.
nonisolated struct LibraryIndex: Sendable {
    /// The snippets in the file's order.
    let snippets: [Snippet]
    /// The snippets by name, ignoring case and accents, with numbers in numeric order.
    let byName: [Snippet]
    /// Each snippet's text by name, for `{snippet name="..."}`.
    let textsByName: [String: String]
    /// Collection names, sorted.
    let collections: [String]
    /// The first UTF-8 byte of every keyword, without the prefix, so root search can turn other
    /// queries away at once.
    let keywordInitials: Set<UInt8>

    private let positions: [String: Int]
    private let idsByName: [String: String]
    private let idsByKeyword: [String: String]
    private let argumentsByID: [String: [TemplateArgument]]
    private let includersByName: [String: [String]]

    static let empty = LibraryIndex([])

    /// Parses every snippet's template once. Call it from a background task for large libraries:
    /// ``build(_:)`` does.
    init(_ snippets: [Snippet]) {
        self.snippets = snippets
        self.byName = snippets.sorted {
            $0.name.compare($1.name, options: [.caseInsensitive, .diacriticInsensitive, .numeric]) == .orderedAscending
        }
        var positions: [String: Int] = [:]
        var idsByName: [String: String] = [:]
        var idsByKeyword: [String: String] = [:]
        var textsByName: [String: String] = [:]
        var argumentsByID: [String: [TemplateArgument]] = [:]
        var includersByName: [String: [String]] = [:]
        var collections = Set<String>()
        for (position, snippet) in snippets.enumerated() {
            // The first snippet wins when a hand-edited file repeats an ID, a name or a keyword.
            if positions[snippet.id] == nil { positions[snippet.id] = position }
            if idsByName[snippet.name] == nil {
                idsByName[snippet.name] = snippet.id
                textsByName[snippet.name] = snippet.text
            }
            if let keyword = snippet.keyword, idsByKeyword[keyword] == nil { idsByKeyword[keyword] = snippet.id }
            if let collection = snippet.collection { collections.insert(collection) }
            let template = Template(snippet.text)
            let arguments = template.arguments
            if !arguments.isEmpty { argumentsByID[snippet.id] = arguments }
            for placeholder in template.placeholders {
                if case .snippet(let included) = placeholder.kind,
                    !(includersByName[included]?.contains(snippet.name) ?? false)
                {
                    includersByName[included, default: []].append(snippet.name)
                }
            }
        }
        self.positions = positions
        self.idsByName = idsByName
        self.idsByKeyword = idsByKeyword
        self.textsByName = textsByName
        self.argumentsByID = argumentsByID
        self.includersByName = includersByName
        self.collections = collections.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        self.keywordInitials = Set(idsByKeyword.keys.compactMap(\.utf8.first))
    }

    /// Builds the index on a background thread.
    @concurrent static func build(_ snippets: [Snippet]) async -> LibraryIndex {
        LibraryIndex(snippets)
    }

    var isEmpty: Bool { snippets.isEmpty }

    func snippet(id: String) -> Snippet? {
        positions[id].map { snippets[$0] }
    }

    func snippet(named name: String) -> Snippet? {
        idsByName[name].flatMap(snippet(id:))
    }

    /// The snippet with this keyword, written without the shared prefix.
    func snippet(keyword: some StringProtocol) -> Snippet? {
        idsByKeyword[String(keyword)].flatMap(snippet(id:))
    }

    /// The arguments the snippet asks for before it pastes, in order. Empty for most snippets.
    func arguments(of id: String) -> [TemplateArgument] {
        argumentsByID[id] ?? []
    }

    /// Names of the snippets whose text includes this one with `{snippet name="..."}`.
    func includers(of name: String) -> [String] {
        includersByName[name] ?? []
    }
}
