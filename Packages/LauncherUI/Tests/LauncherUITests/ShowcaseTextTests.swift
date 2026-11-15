import AppKit
import LauncherUITesting
import Testing

@testable import LauncherUI

/// The showcase pictures are published, so their sample text must read as an ordinary note and
/// fit the pane it is shown in.
@Suite(.timeLimit(.minutes(1)))
struct ShowcaseTextTests {
    @Test func theNoteAndTheFormSayNothingAboutSoftwareReleases() {
        var texts = [ShowcaseCatalog.markdown]
        texts += ShowcaseCatalog.metadata.compactMap { item in
            switch item {
            case .label(_, let value), .iconLabel(_, let value, _): value
            case .tags(_, let tags): tags.map(\.text).joined(separator: " ")
            default: nil
            }
        }
        for item in ShowcaseCatalog.noteForm().items {
            switch item.value {
            case .text(let text): texts.append(text)
            case .tags(let tags): texts.append(tags.joined(separator: " "))
            default: break
            }
        }
        texts += ShowcaseCatalog.fileRows().sections.flatMap(\.rows).map(\.title)
        let words = ["beta", "crash", "release", "version", "launch", "tester", "build", "make "]
        for text in texts {
            for word in words {
                #expect(!text.lowercased().contains(word), "“\(text)” mentions \(word)")
            }
        }
    }

    @Test func theNotesCodeBlockFitsOnOneLineBesideTheList() throws {
        let width = (Theme.standard.panel.width * (1 - Theme.standard.detail.listFraction)).rounded()
        let pane = DetailPane(frame: CGRect(x: 0, y: 0, width: width, height: 500))
        pane.apply(TestSupport.lightTheme)
        pane.apply(DetailContent(body: .markdown(ShowcaseCatalog.markdown), metadata: ShowcaseCatalog.metadata))
        pane.layoutSubtreeIfNeeded()
        let code = "500 g flour · 350 g water · 10 g salt"
        #expect(pane.bodyText.contains(code))
        #expect(try MarkdownLineBreakTests.lineFragments(in: pane, paragraph: code) == 1)
    }
}
