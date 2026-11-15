import Foundation
import Kit
import KitTesting
import Synchronization
import Testing

@testable import Platform

/// The selection logic runs over trees of fake elements. No test reads another app.
@Suite(.timeLimit(.minutes(1))) struct SelectionTests {
    @Test func selectedTextIsReturnedAndOneWebAddressBecomesAURL() async {
        let permissions = FakePermissions()
        let text = FakeElement(["AXSelectedText": .text("synthetic words")])
        #expect(await service(text, permissions).currentSelection() == .text("synthetic words"))

        let link = FakeElement(["AXSelectedText": .text(" https://example.com/page \n")])
        #expect(await service(link, permissions).currentSelection() == .url(URL(string: "https://example.com/page")!))

        let sentence = FakeElement(["AXSelectedText": .text("see https://example.com")])
        #expect(await service(sentence, permissions).currentSelection() == .text("see https://example.com"))

        let blank = FakeElement(["AXSelectedText": .text("  ")])
        #expect(await service(blank, permissions).currentSelection() == nil)
    }

    @Test func selectedRowsGiveFilesAndFoldersHaveDirectoryPaths() async throws {
        let file = URL(filePath: "/synthetic/notes.txt")
        let folder = URL(filePath: "/synthetic/Projects")
        let slashed = URL(filePath: "/synthetic/Archive/", directoryHint: .isDirectory)
        // The URL may sit on the row or on a cell below it.
        let rows: [any AccessibilityElement] = [
            FakeElement(["AXURL": .url(file)]),
            FakeElement(["AXChildren": .elements([FakeElement([:]), FakeElement(["AXURL": .url(folder)])])]),
            FakeElement(["AXChildren": .elements([FakeElement(["AXURL": .text(slashed.absoluteString)])])]),
            FakeElement(["AXURL": .url(file)]),  // a duplicate
            FakeElement(["AXURL": .url(URL(string: "https://example.com")!)]),  // not a file
        ]
        let list = FakeElement(["AXSelectedRows": .elements(rows)])
        let selection = await service(list, FakePermissions(), folders: ["/synthetic/Projects"]).currentSelection()
        guard case .files(let urls)? = selection else {
            Issue.record("expected files, got \(String(describing: selection))")
            return
        }
        #expect(
            urls.map { $0.path(percentEncoded: false) } == [
                "/synthetic/notes.txt", "/synthetic/Projects/", "/synthetic/Archive/",
            ])
        #expect(urls.map(\.hasDirectoryPath) == [false, true, true])
    }

    @Test func selectedChildrenAreUsedWhenThereAreNoRows() async {
        let file = URL(filePath: "/synthetic/image.png")
        let icons = FakeElement(["AXSelectedChildren": .elements([FakeElement(["AXURL": .url(file)])])])
        #expect(await service(icons, FakePermissions()).currentSelection() == .files([file]))
    }

    @Test func withoutAccessibilityNothingIsRead() async {
        let permissions = FakePermissions()
        permissions.set(.accessibility, to: .denied)
        let element = FakeElement(["AXSelectedText": .text("synthetic")])
        #expect(await service(element, permissions).currentSelection() == nil)
        #expect(element.reads == 0)
        #expect(permissions.requests.isEmpty)
    }

    @Test func noFocusedElementMeansNoSelection() async {
        let service = AccessibilitySelection(permissions: FakePermissions()) { nil }
        #expect(await service.currentSelection() == nil)
        #expect(await NoSelection().currentSelection() == nil)
    }

    @Test func searchingBelowARowStopsAtTheDepthLimit() {
        let deep = URL(filePath: "/synthetic/deep.txt")
        var element: any AccessibilityElement = FakeElement(["AXURL": .url(deep)])
        for _ in 0..<5 {
            element = FakeElement(["AXChildren": .elements([element])])
        }
        #expect(SelectionReader.fileURL(in: element, depth: 0) == nil)
    }

    func service(
        _ focused: FakeElement, _ permissions: FakePermissions, folders: Set<String> = []
    ) -> AccessibilitySelection {
        AccessibilitySelection(
            permissions: permissions, focusedElement: { focused },
            isDirectory: { url in folders.contains(url.path(percentEncoded: false)) })
    }
}

/// An accessibility element with fixed attributes. Counts its reads.
nonisolated final class FakeElement: AccessibilityElement {
    private let attributes: [String: AccessibilityValue]
    private let readCount = Mutex(0)

    init(_ attributes: [String: AccessibilityValue]) {
        self.attributes = attributes
    }

    var reads: Int { readCount.withLock { $0 } }

    func value(of attribute: String) -> AccessibilityValue? {
        readCount.withLock { $0 += 1 }
        return attributes[attribute]
    }
}
