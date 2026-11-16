import Foundation
import Kit

/// Reads the files Import Snippets accepts: a JSON list in Raycast's shape, which this feature's
/// export writes too, this feature's own data file, and an Alfred snippet collection, a ZIP archive
/// ending in `.alfredsnippets`.
///
/// Every file is treated as hostile. The format is told by the bytes, not the name. Nothing is
/// written to disk, and nothing is read past the limits.
nonisolated enum SnippetImportFile {
    /// The largest file read, in bytes.
    static let maximumFileSize = 52_428_800
    /// The most entries a JSON file may hold.
    static let maximumJSONEntries = 10_000
    /// The extension Alfred gives its snippet collections.
    static let alfredExtension = "alfredsnippets"

    /// Why a file was not imported. Nothing of it is used.
    enum Failure: Error, Hashable, Sendable {
        case unreadable
        case tooLarge
        case notSnippets
        case tooManyEntries
        case archive(ZipError)
    }

    /// Reads a file the user chose in the open dialog, off the main thread.
    @concurrent static func read(_ url: URL) async throws(Failure) -> [ImportedEntry] {
        let data = try readBytes(url)
        return try parse(data, fileName: url.lastPathComponent)
    }

    /// At most ``maximumFileSize`` bytes of a regular file. A larger file throws without being read
    /// to the end.
    static func readBytes(_ url: URL, limit: Int = maximumFileSize) throws(Failure) -> Data {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { throw .unreadable }
        if let size = values?.fileSize, size > limit { throw .tooLarge }
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw .unreadable }
        defer { try? handle.close() }
        let data: Data
        do {
            // Nil means the file is empty.
            data = try handle.read(upToCount: limit + 1) ?? Data()
        } catch {
            throw .unreadable
        }
        guard data.count <= limit else { throw .tooLarge }
        return data
    }

    /// The entries in a file's bytes. `fileName` names an Alfred collection after its file.
    static func parse(_ data: Data, fileName: String) throws(Failure) -> [ImportedEntry] {
        if ZipArchive.looksLikeArchive(data) {
            let archive: ZipArchive
            do {
                archive = try ZipArchive(data)
            } catch {
                throw .archive(error)
            }
            return try alfred(archive, collection: collectionName(fileName))
        }
        return try json(data)
    }

    // MARK: JSON

    /// A list of entries, or an object with one under `snippets`. Each entry's text keeps Raycast's
    /// placeholders, which are this feature's too; the ones it lacks are noted.
    static func json(_ data: Data) throws(Failure) -> [ImportedEntry] {
        let file: ImportFile
        do {
            file = try JSONDecoder().decode(ImportFile.self, from: withoutByteOrderMark(data))
        } catch is ImportFile.TooMany {
            throw .tooManyEntries
        } catch {
            throw .notSnippets
        }
        return file.entries.map { entry in
            guard let text = entry.text else { return ImportedEntry(entry) }
            let mapped = PlaceholderMapping.raycast(text)
            return ImportedEntry(entry, keptAsTyped: mapped.keptAsTyped, nowFilled: mapped.nowFilled)
        }
    }

    /// The data without a UTF-8 byte order mark at its start.
    static func withoutByteOrderMark(_ data: Data) -> Data {
        data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
    }

    // MARK: Alfred

    /// An Alfred collection: one JSON file per snippet at the top level, and an optional
    /// `info.plist` with the prefix and suffix Alfred adds around every keyword. Other files, such
    /// as an icon, are not read.
    static func alfred(_ archive: ZipArchive, collection: String?) throws(Failure) -> [ImportedEntry] {
        var prefix = ""
        var suffix = ""
        if let info = archive.entries.first(where: { $0.name == "info.plist" }) {
            let data: Data
            do {
                data = try archive.contents(of: info)
            } catch {
                throw .archive(error)
            }
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
            if let settings = plist as? [String: Any] {
                prefix = settings["snippetkeywordprefix"] as? String ?? ""
                suffix = settings["snippetkeywordsuffix"] as? String ?? ""
            }
        }
        let files = archive.entries.filter { $0.name.lowercased().hasSuffix(".json") }
        guard !files.isEmpty else { throw .notSnippets }
        var entries: [ImportedEntry] = []
        for file in files {
            let data: Data
            do {
                data = try archive.contents(of: file)
            } catch {
                throw .archive(error)
            }
            guard let snippet = (try? JSONDecoder().decode(AlfredFile.self, from: withoutByteOrderMark(data)))?.snippet
            else {
                entries.append(ImportedEntry(TransferEntry()))
                continue
            }
            let mapped = snippet.snippet.map(PlaceholderMapping.alfred)
            let keyword = Snippet.clean(snippet.keyword).map { prefix + $0 + suffix }
            let entry = TransferEntry(
                name: snippet.name, text: mapped?.text, keyword: keyword, collection: collection,
                expands: !(snippet.dontautoexpand ?? false))
            entries.append(
                ImportedEntry(entry, keptAsTyped: mapped?.keptAsTyped ?? [], nowFilled: mapped?.nowFilled ?? []))
        }
        return entries
    }

    /// The collection an Alfred file names: its name without the extension.
    static func collectionName(_ fileName: String) -> String? {
        let suffix = "." + alfredExtension
        let base = fileName.lowercased().hasSuffix(suffix) ? String(fileName.dropLast(suffix.count)) : fileName
        return ImportText.line(base)
    }
}

/// One file of an Alfred collection: `{"alfredsnippet": {...}}`.
private nonisolated struct AlfredFile: Decodable {
    private enum CodingKeys: String, CodingKey {
        case snippet = "alfredsnippet"
    }

    var snippet: AlfredSnippet?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snippet = try? container.decodeIfPresent(AlfredSnippet.self, forKey: .snippet)
    }
}

/// An Alfred snippet. A field of the wrong type counts as missing.
private nonisolated struct AlfredSnippet: Decodable {
    private enum CodingKeys: String, CodingKey {
        case snippet, name, keyword, dontautoexpand
    }

    var snippet: String?
    var name: String?
    var keyword: String?
    var dontautoexpand: Bool?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snippet = try? container.decodeIfPresent(String.self, forKey: .snippet)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        keyword = try? container.decodeIfPresent(String.self, forKey: .keyword)
        dontautoexpand = try? container.decodeIfPresent(Bool.self, forKey: .dontautoexpand)
    }
}

/// An import file: an array of entries, or an object holding one under `snippets`.
private nonisolated struct ImportFile: Decodable {
    struct TooMany: Error {}

    private enum CodingKeys: String, CodingKey {
        case snippets
    }

    /// Decodes nothing, so an entry that is not an object can be stepped over.
    private struct Skip: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    var entries: [TransferEntry] = []

    init(from decoder: any Decoder) throws {
        var array: any UnkeyedDecodingContainer
        if let top = try? decoder.unkeyedContainer() {
            array = top
        } else {
            array = try decoder.container(keyedBy: CodingKeys.self).nestedUnkeyedContainer(forKey: .snippets)
        }
        if let count = array.count, count > SnippetImportFile.maximumJSONEntries { throw TooMany() }
        while !array.isAtEnd {
            guard entries.count < SnippetImportFile.maximumJSONEntries else { throw TooMany() }
            if let entry = try? array.decode(TransferEntry.self) {
                entries.append(entry)
            } else {
                // Not an object: step over it and count it as not valid.
                _ = try array.decode(Skip.self)
                entries.append(TransferEntry())
            }
        }
    }
}
