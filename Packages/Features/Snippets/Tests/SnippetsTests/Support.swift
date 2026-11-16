import Foundation
import Kit
import KitStorage
import KitTesting
import Testing

@testable import Snippets

/// Synthetic snippets for tests. Nothing here comes from a real person.
enum Fixture {
    static func snippet(
        _ name: String, _ text: String, keyword: String? = nil, collection: String? = nil, expands: Bool = true,
        pinned: Bool = false, id: String? = nil
    ) -> Snippet {
        Snippet(
            id: id ?? "id-" + name.lowercased().replacingOccurrences(of: " ", with: "-"), name: name, text: text,
            keyword: keyword, collection: collection, expands: expands, isPinned: pinned)
    }

    static let greeting = snippet("Greeting", "Hello there", keyword: "hi")
    static let signoff = snippet("Sign Off", "Best,\n{cursor}\nThe Team", keyword: "sig", collection: "Email")
    static let address = snippet("Office Address", "1 Example Way\nSample Town", keyword: "addr", collection: "Email")
    static let bug = snippet("Bug Template", "Steps:\n1. {cursor}", collection: "Work", pinned: true)
}

extension FeatureHarness where F == SnippetsFeature {
    /// Makes a harness whose snippets file holds exactly these snippets, so no starters are added,
    /// then activates the feature and waits for the first load.
    static func loaded(_ snippets: [Snippet], fakes: FakeServices = FakeServices()) async throws -> FeatureHarness<
        SnippetsFeature
    > {
        let harness = FeatureHarness(SnippetsFeature.self, fakes: fakes)
        try await harness.writeFile(snippets)
        await harness.start()
        return harness
    }

    /// Activates the feature and waits until the snippets are loaded and expansion has started.
    func start() async {
        await activate()
        await feature.ready()
    }

    var library: SnippetLibrary { feature.library }
    var file: URL { feature.library.fileURL }

    func writeFile(_ snippets: [Snippet]) async throws {
        try await JSONFileStore<SnippetFile>(url: file).save(SnippetFile(snippets: snippets))
    }

    /// What the file on disk holds now.
    func storedSnippets() async throws -> [Snippet] {
        try #require(try await JSONFileStore<SnippetFile>(url: file).load()).snippets
    }

    func snippet(named name: String) -> Snippet? {
        library.index.snippet(named: name)
    }

    /// Plays the file changing on disk and waits until the feature has read it again.
    func announceFileChange() async throws {
        fakes.fileWatcher.simulateChange([file])
        try await settle()
    }

    /// Opens Search Snippets.
    func openSearch() async throws {
        try await run(SnippetIDs.searchCommand)
    }

    /// The import page on top, when Import Snippets showed one.
    var importPage: SnippetImportPage? {
        guard case .list(let list)? = page?.page else { return nil }
        return list.source as? SnippetImportPage
    }

    /// Runs Import Snippets on these files and, when it shows its page, presses Return on it, as a
    /// person who agrees with the page would.
    func importAndConfirm(_ files: [URL]) async throws {
        fakes.fileDialogs.filesToChoose = files
        try await run(SnippetIDs.importCommand)
        guard importPage != nil else { return }
        try await performPrimary()
    }

    /// Titles of the import page's rows, by section ID.
    var importSections: [String: [String]] {
        Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0.rows.map(\.title)) })
    }

    /// Selects a row by title and returns its actions' IDs.
    func actionIDs(of title: String) throws -> [String] {
        try select(title: title)
        return actions().map(\.id)
    }
}

/// Writes raw bytes, for damaged files.
func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}
