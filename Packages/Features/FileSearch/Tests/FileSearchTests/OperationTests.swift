import Darwin
import Foundation
import Kit
import Testing

@testable import FileSearch

/// The steps every file action takes on disk, through the operations for tests, which act only
/// inside a synthetic tree under the system's temporary folder.
@Suite("File operations", .timeLimit(.minutes(1)))
struct OperationTests {
    private let tree: TestTree
    private let operations: TreeFileOperations

    init() throws {
        tree = try TestTree()
        operations = TreeFileOperations(root: tree.root.path(percentEncoded: false))
    }

    private func names(_ relative: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: tree.path(relative)).sorted()
    }

    private func expectFailure(_ expected: FileOperationError, _ work: () async throws -> URL) async {
        do {
            let made = try await work()
            Issue.record("expected \(expected), made \(made.path)")
        } catch let error as FileOperationError {
            #expect(error == expected)
        } catch {
            Issue.record("expected \(expected), got \(error)")
        }
    }

    @Test func renameKeepsTheFolderAndNeverReplacesAnItem() async throws {
        let renamed = try await operations.rename(tree.url("notes.md"), to: "summary.md")
        #expect(renamed.path(percentEncoded: false) == tree.path("summary.md"))
        #expect(try names("").contains("summary.md") && !names("").contains("notes.md"))

        try tree.write("Archive/big.bin", size: 64)
        try tree.write("Archive/small.bin", size: 8)
        await expectFailure(.nameTaken("big.bin")) {
            try await operations.rename(tree.url("Archive/small.bin"), to: "big.bin")
        }
        let big = try FileManager.default.attributesOfItem(atPath: tree.path("Archive/big.bin"))
        #expect((big[.size] as? NSNumber)?.intValue == 64, "the item that had the name is untouched")
        #expect(try names("Archive").contains("small.bin"))

        // The same name does nothing; a change of case alone is a rename, not a collision.
        #expect(try await operations.rename(tree.url("beach.jpg"), to: "beach.jpg").lastPathComponent == "beach.jpg")
        #expect(await operations.isTaken("BEACH.JPG", besides: tree.url("beach.jpg")) == false)
        #expect(await operations.isTaken("summary.md", besides: tree.url("beach.jpg")))
        _ = try await operations.rename(tree.url("beach.jpg"), to: "Beach.jpg")
        #expect(try names("").contains("Beach.jpg"))
        await expectFailure(.missing) { try await operations.rename(tree.url("gone.txt"), to: "back.txt") }
    }

    @Test func aTypedNameFollowsTheRules() async throws {
        let refused: [(String, FileNames.Problem)] = [
            ("", .empty), (".", .dots), ("..", .dots), ("a/b", .slash), ("a:b", .colon), ("two\nlines", .control),
            ("nul\u{0}", .control), (".hidden", .leadingDot), (String(repeating: "é", count: 128), .tooLong),
        ]
        for (name, problem) in refused {
            #expect(FileNames.problem(with: name) == problem, "\(name.debugDescription)")
            await expectFailure(.invalidName(problem)) { try await operations.rename(tree.url("notes.md"), to: name) }
        }
        for name in ["summary.md", "naïve 猫.txt", "Report (final) 2.pdf", String(repeating: "a", count: 255)] {
            #expect(FileNames.problem(with: name) == nil, "\(name)")
        }
        #expect(FileNames.cleaned("  spaced.txt \n") == "spaced.txt")
        #expect(try names("").contains("notes.md"), "nothing was renamed")
    }

    @Test func copiesAndArchivesTakeFindersNextFreeName() async throws {
        #expect(FileNames.copyName(of: "notes.md", number: 1) == "notes copy.md")
        #expect(FileNames.copyName(of: "notes.md", number: 2) == "notes copy 2.md")
        #expect(FileNames.copyName(of: "notes copy.md", number: 2) == "notes copy 2.md")
        #expect(FileNames.copyName(of: "notes copy 7.md", number: 3) == "notes copy 3.md")
        #expect(FileNames.copyName(of: "Projects", number: 1) == "Projects copy")
        #expect(FileNames.copyName(of: "Tool.app", number: 1) == "Tool copy.app")
        #expect(FileNames.copyName(of: ".zshrc", number: 1) == ".zshrc copy")
        #expect(FileNames.copyName(of: "Version 1.2 notes", number: 1) == "Version 1.2 notes copy")
        #expect(FileNames.archiveName(of: "Projects", number: 1) == "Projects.zip")
        #expect(FileNames.archiveName(of: "report.pdf", number: 2) == "report.pdf 2.zip")
        #expect(FileNames.numbered("notes.md", 2) == "notes 2.md")

        #expect(try await operations.duplicate(tree.url("notes.md")).lastPathComponent == "notes copy.md")
        #expect(try await operations.duplicate(tree.url("notes.md")).lastPathComponent == "notes copy 2.md")
        #expect(try await operations.duplicate(tree.url("notes copy.md")).lastPathComponent == "notes copy 3.md")
        let folder = try await operations.duplicate(tree.url("Projects"))
        #expect(folder.lastPathComponent == "Projects copy" && folder.hasDirectoryPath)
        #expect(try names("Projects copy/app/src") == ["main.swift"], "a folder is copied with what it holds")
        #expect(try names("Projects/app/src") == ["main.swift"], "the original stays")
        // Copy To into the item's own folder is a duplicate.
        let beside = try await operations.copy(tree.url("beach.jpg"), into: tree.url(""))
        #expect(beside.lastPathComponent == "beach copy.jpg")
    }

    @Test func compressMakesAZipBesideTheItem() async throws {
        let archive = try await operations.compress(tree.url("notes.md"))
        #expect(archive.lastPathComponent == "notes.md.zip")
        let data = try Data(contentsOf: archive)
        #expect(data.starts(with: [0x50, 0x4B]), "a zip archive")
        #expect(try await operations.compress(tree.url("notes.md")).lastPathComponent == "notes.md 2.zip")
        let folder = try await operations.compress(tree.url("Projects"))
        #expect(folder.lastPathComponent == "Projects.zip")
        #expect(try names("").contains("Projects") && names("").contains("notes.md"), "the originals stay")
        await expectFailure(.missing) { try await operations.compress(tree.url("gone.txt")) }
        #expect(!(try names("").contains("gone.txt.zip")), "a failed run leaves no file behind")
    }

    @Test func moveNeverReplacesAndRefusesItselfAndItsOwnFolder() async throws {
        let moved = try await operations.move(tree.url("notes.md"), into: tree.url("Archive"))
        #expect(moved.path(percentEncoded: false) == tree.path("Archive/notes.md"))
        #expect(try names("Archive") == ["notes.md", "old-photos.zip"])

        try tree.write("Archive/beach.jpg", size: 64)
        await expectFailure(.nameTaken("beach.jpg")) {
            try await operations.move(tree.url("beach.jpg"), into: tree.url("Archive"))
        }
        let kept = try FileManager.default.attributesOfItem(atPath: tree.path("Archive/beach.jpg"))
        #expect((kept[.size] as? NSNumber)?.intValue == 64)
        #expect(try names("").contains("beach.jpg"))

        await expectFailure(.intoItself) {
            try await operations.move(tree.url("Projects"), into: tree.url("Projects/app"))
        }
        await expectFailure(.intoItself) { try await operations.move(tree.url("Projects"), into: tree.url("Projects")) }
        await expectFailure(.alreadyThere) { try await operations.move(tree.url("beach.jpg"), into: tree.url("")) }
        await expectFailure(.notAFolder) {
            try await operations.move(tree.url("beach.jpg"), into: tree.url("report-2024.pdf"))
        }
        await expectFailure(.notAFolder) { try await operations.move(tree.url("beach.jpg"), into: tree.url("Nowhere")) }
    }

    @Test func copyIntoAnotherFolderFailsOnACollision() async throws {
        let copy = try await operations.copy(tree.url("report-2024.pdf"), into: tree.url("Archive"))
        #expect(copy.path(percentEncoded: false) == tree.path("Archive/report-2024.pdf"))
        #expect(try names("").contains("report-2024.pdf"), "the original stays")
        await expectFailure(.nameTaken("report-2024.pdf")) {
            try await operations.copy(tree.url("report-2024.pdf"), into: tree.url("Archive"))
        }
        await expectFailure(.intoItself) {
            try await operations.copy(tree.url("Projects"), into: tree.url("Projects/app"))
        }
    }

    @Test func theTreesTrashIsInsideTheTree() async throws {
        let first = try await operations.trash(tree.url("notes.md"))
        #expect(first.path(percentEncoded: false) == tree.root.path(percentEncoded: false) + ".Trash/notes.md")
        try tree.write("notes.md")
        let second = try await operations.trash(tree.url("notes.md"))
        #expect(second.lastPathComponent == "notes 2.md", "the Trash never replaces an item either")
        #expect(!(try names("").contains("notes.md")))
    }

    @Test func nothingOutsideTheTreeIsTouched() async throws {
        let other = try TestTree()
        await expectFailure(.outsideTree) { try await operations.rename(other.url("notes.md"), to: "x.md") }
        await expectFailure(.outsideTree) { try await operations.trash(other.url("notes.md")) }
        await expectFailure(.outsideTree) {
            try await operations.move(tree.url("notes.md"), into: other.url("Archive"))
        }
        await expectFailure(.outsideTree) {
            try await operations.copy(tree.url("notes.md"), into: other.url("Archive"))
        }
        // A link inside the tree that leads out of it is refused once resolved.
        #expect(symlink(other.path("Archive"), tree.path("Exit")) == 0)
        await expectFailure(.outsideTree) { try await operations.move(tree.url("notes.md"), into: tree.url("Exit")) }
        await expectFailure(.outsideTree) { try await operations.rename(tree.url("Exit/old-photos.zip"), to: "x.zip") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: other.path("Archive")) == ["old-photos.zip"])
        #expect(FileManager.default.fileExists(atPath: other.path("notes.md")))
        // A root that would reach the user's files refuses everything, before it looks at anything.
        for root in ["/", NSHomeDirectory(), "/Users"] {
            let wide = TreeFileOperations(root: root)
            await expectFailure(.outsideTree) { try await wide.rename(tree.url("notes.md"), to: "x.md") }
        }
        #expect(FileManager.default.fileExists(atPath: tree.path("notes.md")))
    }
}
