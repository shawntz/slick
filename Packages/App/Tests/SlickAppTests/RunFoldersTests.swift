import Foundation
import Kit
import Testing

@testable import SlickApp

/// The data folder belongs to this account alone: every mode makes it with mode 0700, also when
/// `--data-dir` names it, and a folder that is already there with a wider mode is tightened.
@Suite("Run folders", .serialized, .timeLimit(.minutes(1)))
struct RunFoldersTests {
    /// A new scratch folder for one test. The caller deletes it.
    static func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "app-run-folders-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The permission bits of a file or folder, following a link.
    static func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o7777
    }

    static func setMode(_ mode: Int, of url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    static func folders(_ arguments: [String]) throws -> RunFolders {
        RunFolders.resolve(try LaunchOptions(arguments: arguments), currentDirectory: "/")
    }

    @Test func everyModeMakesTheDataFolderForThisAccountOnly() throws {
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let modes: [[String]] = [[], ["--selftest"], ["--bench"], ["--scenario", "x.json"]]
        for (index, arguments) in modes.enumerated() {
            let folder = scratch.appending(path: "custom-\(index)/data", directoryHint: .isDirectory)
            let folders = try Self.folders(arguments + ["--data-dir", folder.path])
            #expect(!folders.isTemporary)
            try folders.create()
            #expect(try Self.mode(folders.dataRoot) == 0o700, "\(arguments)")
            // A folder made on the way is no wider.
            #expect(try Self.mode(folder.deletingLastPathComponent()) == 0o700, "\(arguments)")
        }
        let temporary = try Self.folders(["--selftest"])
        #expect(temporary.isTemporary)
        try temporary.create()
        defer { temporary.removeIfTemporary() }
        #expect(try Self.mode(temporary.dataRoot) == 0o700)
    }

    @Test func aWiderFolderIsTightenedAtLaunch() throws {
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        for wide in [0o755, 0o775, 0o777, 0o750, 0o701] {
            let folder = scratch.appending(path: "custom-\(String(wide, radix: 8))", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try Self.setMode(wide, of: folder)
            let file = folder.appending(path: "kept.txt")
            try Data("kept".utf8).write(to: file)
            try Self.folders(["--data-dir", folder.path]).create()
            #expect(try Self.mode(folder) == 0o700, "from \(String(wide, radix: 8))")
            #expect(try Data(contentsOf: file) == Data("kept".utf8), "what the folder holds stays")
        }
    }

    @Test func aFolderNarrowerThanThatIsLeftAlone() throws {
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folder = scratch.appending(path: "narrow", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Self.setMode(0o500, of: folder)
        defer { try? Self.setMode(0o700, of: folder) }
        try Self.folders(["--data-dir", folder.path]).create()
        #expect(try Self.mode(folder) == 0o500)
    }

    @Test func aLinkToAFolderTightensTheFolderItNames() throws {
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let target = scratch.appending(path: "target", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Self.setMode(0o755, of: target)
        let link = scratch.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try Self.folders(["--selftest", "--data-dir", link.path]).create()
        #expect(try Self.mode(target) == 0o700)
    }

    @Test func aFileWhereTheFolderShouldBeIsAnError() throws {
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appending(path: "not-a-folder")
        try Data().write(to: file)
        #expect(throws: (any Error).self) { try Self.folders(["--selftest", "--data-dir", file.path]).create() }
    }
}
