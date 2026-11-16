import Foundation
import Kit
import Testing

@testable import MarkdownNotes

@Suite("Note text", .timeLimit(.minutes(1)))
struct TextTests {
    @Test func theTitleIsTheFirstHeadingOrTheFirstLine() {
        let heading = NoteText.parse("# Groceries\n\nMilk\n")
        #expect(heading.title == "Groceries")
        #expect(heading.style == .heading(1))
        #expect(heading.body == "Milk")

        let line = NoteText.parse("Call the plumber\nabout the sink\n")
        #expect(line.title == "Call the plumber")
        #expect(line.style == .line)
        #expect(line.body == "about the sink")

        let setext = NoteText.parse("Plans\n=====\n\nSoon\n")
        #expect(setext.title == "Plans")
        #expect(setext.style == .underlined("="))
        #expect(setext.body == "Soon")

        // A heading further down never becomes the title.
        let later = NoteText.parse("Groceries\n- milk\n\n## Later\n- bread\n")
        #expect(later.title == "Groceries")

        // Front matter and blank lines come before the title.
        let front = NoteText.parse("---\ntags: [a]\n---\n\n\n## Real Title ##\nbody\n")
        #expect(front.frontMatter == "---\ntags: [a]\n---\n")
        #expect(front.title == "Real Title")
        #expect(front.style == .heading(2))

        // A heading mark needs a space, and C# keeps its mark.
        #expect(NoteText.parse("#hashtag only\n").style == .line)
        #expect(NoteText.parse("# Learning C#\n").title == "Learning C#")

        // Nothing visible means no title.
        #expect(NoteText.parse("\u{200B}\n \n").style == .none)
        #expect(NoteText.parse("").style == .none)
    }

    @Test func tagsAreALastLineOfTagsAndNothingElse() {
        let note = NoteText.parse("# Sync\n\nAgenda #1 and #draft ideas\n\n#work #team/alpha #Work\n")
        #expect(note.tags == ["work", "team/alpha"])
        #expect(note.body == "Agenda #1 and #draft ideas")

        // Digits alone are not a tag, so the line stays text.
        #expect(NoteText.parse("# T\n\nbody\n#42\n").tags.isEmpty)
        // A line with words besides tags stays text.
        #expect(NoteText.parse("# T\n\nsee #work today\n").tags.isEmpty)
        // A tag line inside an open code fence is code.
        let code = NoteText.parse("# T\n\n```c\n#include\n")
        #expect(code.tags.isEmpty)
        #expect(code.body == "```c\n#include")
        // The title line is never the tag line.
        let only = NoteText.parse("#ideas\n")
        #expect(only.title == "#ideas")
        #expect(only.tags.isEmpty)
    }

    @Test func composedTextReadsBackToTheSameParts() {
        let samples = [
            NoteText(title: "Groceries", style: .heading(1), body: "Milk\n\n- eggs", tags: ["errands"]),
            NoteText(title: "Plain", style: .line, body: "Second line"),
            NoteText(title: "Plans", style: .underlined("-"), body: "", tags: ["a", "b-c"]),
            NoteText(frontMatter: "---\nx: 1\n---\n", title: "Front", style: .heading(3), body: "Text"),
            NoteText(title: "", style: .none, body: "Only a body\nwith two lines"),
        ]
        for sample in samples {
            let text = sample.composed
            #expect(text.hasSuffix("\n"))
            var expected = sample
            if sample.style == .none {
                // With no title, the body's first line becomes the title.
                expected = NoteText(title: "Only a body", style: .line, body: "with two lines")
            }
            #expect(NoteText.parse(text) == expected, "\(text)")
            if sample.style != .none { #expect(NoteText.parse(text).composed == text) }
        }
        #expect(
            NoteText(title: "Groceries", style: .heading(1), body: "Milk", tags: ["errands"]).composed
                == "# Groceries\n\nMilk\n\n#errands\n")
        // A title with line breaks stays on one line.
        #expect(
            NoteText(title: "Two\nlines\u{2028}here", style: .heading(1), body: "").composed == "# Two lines here\n")
    }

    @Test func renamingChangesOnlyTheTitleLine() {
        #expect(NoteText.retitled("  ## Old\nbody  \n\n\nend", title: "New") == "  ## New\nbody  \n\n\nend")
        #expect(NoteText.retitled("Old\nsecond", title: "New") == "New\nsecond")
        #expect(NoteText.retitled("Old\n===\nbody", title: "Brand New") == "Brand New\n===\nbody")
        #expect(NoteText.retitled("---\na: 1\n---\n\n", title: "Fresh") == "---\na: 1\n---\n# Fresh\n")
        #expect(NoteText.retitled("", title: "Fresh") == "# Fresh\n")
        #expect(NoteText.retitled("Old\r\nsecond\r\n", title: "New") == "New\r\nsecond\r\n")
    }

    @Test func appendingAddsTextBeforeTheTagLine() {
        #expect(NoteText.appending("More", to: "# T\n\nBody\n\n#work\n") == "# T\n\nBody\n\nMore\n\n#work\n")
        #expect(NoteText.appending("More", to: "# T\n\nBody") == "# T\n\nBody\n\nMore\n")
        // A list item joins a list.
        #expect(NoteText.appending("- bread", to: "# Shop\n\n- milk\n") == "# Shop\n\n- milk\n- bread\n")
        #expect(NoteText.appending("2. two", to: "1. one\n") == "1. one\n2. two\n")
        #expect(NoteText.appending("First words  \n", to: "") == "First words\n")
        #expect(NoteText.appending("Tagged", to: "#idea\n") == "#idea\n\nTagged\n")
    }

    @Test func plainTextDropsTheMarksAndKeepsTheWords() {
        let markdown = """
            # Title

            Some **bold**, *italic*, _under_ and ~~gone~~ text with `code` and a snake_case_name.
            > Quoted line
            - [ ] task
            * item
            See [the guide](https://example.com/guide) and ![a chart](chart.png) or <https://example.org>.
            Escaped \\*stars\\* stay. 2 * 3 * 4 stays.

            ---

            ```swift
            let **x** = 1
            ```
            """
        let plain = PlainText.of(markdown)
        let expected = [
            "Title", "",
            "Some bold, italic, under and gone text with code and a snake_case_name.",
            "Quoted line", "• [ ] task", "• item",
            "See the guide (https://example.com/guide) and a chart or https://example.org.",
            "Escaped *stars* stay. 2 * 3 * 4 stays.", "", "", "",
            "let **x** = 1",
        ]
        #expect(plain.components(separatedBy: "\n") == expected)
    }

    @Test func fileNamesAreSafeAndUnique() {
        #expect(NoteFileName.base(for: "Plans / Ideas: 2027") == "Plans - Ideas- 2027")
        #expect(NoteFileName.base(for: "Line one\nline two") == "Line one line two")
        #expect(NoteFileName.base(for: "invoice\u{202E}fdp.exe") == "invoicefdp.exe")
        #expect(NoteFileName.base(for: "...hidden. ") == "hidden")
        #expect(NoteFileName.base(for: "\u{200B}\t ") == NoteFileName.untitled)
        #expect(NoteFileName.base(for: "Family 👨‍👩‍👧") == "Family 👨‍👩‍👧")
        let long = NoteFileName.base(for: String(repeating: "é", count: 300))
        #expect(long.count == NoteFileName.maximumCharacters)
        let wide = NoteFileName.base(for: String(repeating: "😀", count: 300))
        #expect(wide.utf8.count <= NoteFileName.maximumBytes)
        // Decomposed accents are composed, as volumes store them.
        #expect(NoteFileName.base(for: "Cafe\u{301}") == "Caf\u{E9}")

        let taken: Set<String> = ["plans.md", "plans 2.md"]
        #expect(NoteFileName.unique("Plans") { taken.contains(NoteFileName.comparable($0)) } == "Plans 3.md")
        #expect(NoteFileName.unique("Other") { taken.contains(NoteFileName.comparable($0)) } == "Other.md")

        #expect(NoteFileName.isNoteFile("Plans.md"))
        #expect(NoteFileName.isNoteFile("Plans.MD"))
        #expect(NoteFileName.isNoteFile("Plans.markdown"))
        #expect(NoteFileName.isNoteFile("line\nbreak.md"))
        #expect(!NoteFileName.isNoteFile("../outside.md"))
        #expect(!NoteFileName.isNoteFile("a/b.md"))
        #expect(!NoteFileName.isNoteFile(".hidden.md"))
        #expect(!NoteFileName.isNoteFile(".md"))
        #expect(!NoteFileName.isNoteFile("notes.txt"))
        #expect(!NoteFileName.isNoteFile("nul\u{0}.md"))
    }

    @Test func bytesBecomeTextOnlyWhenTheyAreText() {
        #expect(NoteDecoding.text(Data([0xEF, 0xBB, 0xBF] + Array("# Hi".utf8)), isCut: false) == "# Hi")
        let utf16 = Data([0xFF, 0xFE]) + "# Hé".data(using: .utf16LittleEndian)!
        #expect(NoteDecoding.text(utf16, isCut: false) == "# Hé")
        #expect(NoteDecoding.text(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]), isCut: false) == nil)
        #expect(NoteDecoding.text(Data((0..<400).map { _ in UInt8(0xFF) }), isCut: false) == nil)
        // A read cut inside "é" drops the half character.
        let cut = Data("abcé".utf8).dropLast()
        #expect(NoteDecoding.text(Data(cut), isCut: true) == "abc")
    }

    @Test func searchFoldsCaseAccentsAndWidth() {
        let query = NoteQuery("  CAFE  budget\u{0}x  ")
        #expect(query.words == ["CAFE", "budget", "x"])
        #expect(NoteSearch.contains(NoteSearch.fold("Notes from the Café"), query.folded[0]))
        #expect(!NoteSearch.contains(NoteSearch.fold("Notes"), query.folded[1]))
        #expect(NoteSearch.contains(NoteSearch.fold("ＢＵＤＧＥＴ"), query.folded[1]))

        // Highlights are UTF-16 offsets and stay right after an emoji.
        let title = "😀 Café budget"
        #expect(NoteSearch.highlights(NoteQuery("cafe budget"), in: title) == [3..<7, 8..<14])

        let text = NoteSearchText("# Trip\n\nFirst line.\nWe must plan the BUDGET for the ferry ride soon.\n")
        let snippet = NoteSearch.snippet(NoteQuery("budget"), foldedTitle: NoteSearch.fold("Trip"), text: text)
        #expect(snippet == "We must plan the BUDGET for the ferry ride soon.")
    }
}
