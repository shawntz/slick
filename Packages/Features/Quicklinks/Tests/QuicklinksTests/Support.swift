import Foundation
import Kit
import KitStorage
import KitTemplates
import KitTesting

@testable import Quicklinks

/// A harness over fakes, with the quicklinks file written first when a test needs one.
@MainActor
struct QuicklinksHarness {
    let harness: FeatureHarness<QuicklinksFeature>

    var fakes: FakeServices { harness.fakes }
    var feature: QuicklinksFeature { harness.feature }
    var fileURL: URL { harness.context.storage.dataFile(QuicklinksFeature.fileName) }

    /// - Parameters:
    ///   - file: Written before the feature activates. Nil starts with no file, as on first launch.
    ///   - raw: Text written as the file instead, for files a person wrote by hand.
    init(file: QuicklinkFile? = nil, raw: String? = nil, activate: Bool = true) async throws {
        harness = FeatureHarness(QuicklinksFeature.self)
        let url = harness.context.storage.dataFile(QuicklinksFeature.fileName)
        if let file { try await JSONFileStore<QuicklinkFile>(url: url).save(file) }
        if let raw {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(raw.utf8).write(to: url)
        }
        if activate { await harness.activate() }
    }

    /// The file as it is on disk now.
    func storedFile() async throws -> QuicklinkFile? {
        try await JSONFileStore<QuicklinkFile>(url: fileURL).load()
    }

    /// Writes the file as another app would, then tells the feature it changed and waits.
    func editFileOnDisk(_ file: QuicklinkFile) async throws {
        try await JSONFileStore<QuicklinkFile>(url: fileURL).save(file)
        fakes.fileWatcher.simulateChange([fileURL])
        try await harness.settle()
    }

    /// Writes raw text as the file, then tells the feature it changed and waits.
    func writeRawFileOnDisk(_ text: String) async throws {
        try Data(text.utf8).write(to: fileURL)
        fakes.fileWatcher.simulateChange([fileURL])
        try await harness.settle()
    }

    /// The command ID of a quicklink with arguments.
    func commandIDs() -> [String] {
        harness.feature.commands.map(\.id)
    }

    /// The catalog row with this title.
    func catalogRow(_ title: String) async throws -> Row {
        let rows = try await harness.catalogRows()
        guard let row = rows.first(where: { $0.title == title }) else { throw TestFailure("no catalog row \(title)") }
        return row
    }

    /// Opens Search Quicklinks and selects the row with this title.
    func selectInList(_ title: String) async throws {
        try await harness.run("search")
        try harness.select(title: title)
    }
}

/// A failure in a test's own setup.
struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// Synthetic quicklinks. Every domain is a reserved example domain.
enum Samples {
    static let docs = Quicklink(id: "sample-docs", name: "Sample Docs", link: "https://docs.example.com/guide")
    static let tracker = Quicklink(
        id: "sample-tracker", name: "Sample Tracker",
        link: "https://tracker.example.com/issues/{argument name=\"Issue\"}",
        keywords: ["issue"])
    static let search = Quicklink(
        id: "sample-search", name: "Sample Search", link: "https://search.example.org/find?q={query}", keywords: ["ss"],
        isFallback: true)
    static let browserID = "com.example.browser"

    /// The built-in searches plus the samples.
    static var file: QuicklinkFile {
        QuicklinkFile(quicklinks: DefaultSearches.all + [docs, tracker, search])
    }

    /// Only the samples, with every built-in search deleted.
    static var samplesOnly: QuicklinkFile {
        QuicklinkFile(quicklinks: [docs, tracker, search], removedDefaults: DefaultSearches.all.map(\.id))
    }
}

/// A template environment with fixed values and nothing to read.
func environment(
    _ arguments: [String: String] = [:], clipboard: String? = nil, selection: String? = nil
) -> TemplateEnvironment {
    TemplateEnvironment(
        now: Date(timeIntervalSince1970: 1_800_000_000), timeZone: TimeZone(identifier: "UTC") ?? .current,
        locale: Locale(identifier: "en_US_POSIX"), arguments: arguments,
        clipboard: { offset in offset == 0 ? clipboard : nil }, selection: { selection },
        makeUUID: { UUID(uuid: (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)) })
}

/// A link template rendered with these values.
func render(_ link: String, _ arguments: [String: String] = [:], clipboard: String? = nil, selection: String? = nil)
    async -> String
{
    await LinkTemplate(link).render(in: environment(arguments, clipboard: clipboard, selection: selection))
}
