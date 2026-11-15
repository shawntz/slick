import Foundation
import KitStorage
import KitTesting
import Testing

@Suite("JSONFileStore")
struct JSONFileStoreTests {
    nonisolated struct Note: Codable, Equatable {
        var title: String
        var created: Date
    }

    private let storage = FakeStorage()

    private func store() throws -> JSONFileStore<[Note]> {
        JSONFileStore(url: storage.dataDirectory(for: "notes").appending(path: "nested/notes.json"))
    }

    @Test func missingFileLoadsAsNil() async throws {
        let store = try store()
        #expect(try await store.load() == nil)
        #expect(try await store.load(default: []) == [])
    }

    @Test func savesReadableJSONAndLoadsItBack() async throws {
        let store = try store()
        let notes = [Note(title: "a/b", created: Date(timeIntervalSince1970: 0))]
        try await store.save(notes)
        #expect(try await store.load() == notes)
        let text = try String(contentsOf: store.url, encoding: .utf8)
        #expect(text.contains("\"title\" : \"a/b\""))
        #expect(text.contains("1970-01-01T00:00:00.000Z"))
    }

    @Test func datesRoundTripToTheMillisecondAndOldFilesStillRead() async throws {
        let store = try store()
        let notes = [Note(title: "precise", created: Date(timeIntervalSince1970: 1_794_648_600.125))]
        try await store.save(notes)
        #expect(try await store.load() == notes)
        try Data(#"[{"title": "old", "created": "1970-01-01T00:00:01Z"}]"#.utf8).write(to: store.url)
        #expect(try await store.load() == [Note(title: "old", created: Date(timeIntervalSince1970: 1))])
    }

    @Test func updatesInOneStepAndLeavesNoTemporaryFiles() async throws {
        let store = try store()
        let first = Note(title: "one", created: Date(timeIntervalSince1970: 0))
        try await store.update(default: []) { $0.append(first) }
        let result = try await store.update(default: []) {
            $0.append(Note(title: "two", created: Date(timeIntervalSince1970: 1)))
        }
        #expect(result.map(\.title) == ["one", "two"])
        let folder = store.url.deletingLastPathComponent()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["notes.json"])
        try await store.delete()
        try await store.delete()
        #expect(try await store.load() == nil)
    }

    @Test func corruptFilesThrowInsteadOfLosingData() async throws {
        let store = try store()
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url)
        await #expect(throws: DecodingError.self) { try await store.load() }
    }
}
