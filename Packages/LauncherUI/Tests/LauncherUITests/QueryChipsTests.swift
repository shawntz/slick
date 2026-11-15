import AppKit
import LauncherUITesting
import Testing

@testable import LauncherUI

/// Records argument changes and commands.
final class ArgumentRecorder: QueryFieldDelegate {
    var values: [Int: String] = [:]
    var commands: [QueryCommand] = []
    func queryField(_ field: QueryField, didChangeText text: String) {}
    func queryField(_ field: QueryField, perform command: QueryCommand) -> Bool {
        commands.append(command)
        return true
    }
    func queryField(_ field: QueryField, argumentAt index: Int, didChange value: String) { values[index] = value }
}

@Suite struct QueryChipsTests {
    func makeField() -> (surface: LauncherSurface, field: QueryField, recorder: ArgumentRecorder) {
        let surface = TestSupport.makeSurface()
        surface.panel.orderFrontRegardless()
        surface.queryField.installEditor()
        let recorder = ArgumentRecorder()
        let field = surface.queryField
        field.delegate = recorder
        field.text = "Search Snippets"
        field.arguments = [
            QueryArgument(placeholder: "Keyword"),
            QueryArgument(kind: .secure, placeholder: "Passphrase"),
            QueryArgument(
                kind: .dropdown([MenuOption(id: "any", title: "Any"), MenuOption(id: "work", title: "Work")]),
                placeholder: "Tag", value: "any"),
        ]
        surface.rootView.layoutSubtreeIfNeeded()
        return (surface, field, recorder)
    }

    @Test func atMostThreeChipsFollowTheText() {
        let (surface, field, _) = makeField()
        defer { surface.panel.close() }
        field.arguments += [QueryArgument(placeholder: "Fourth")]
        #expect(field.argumentChips.count == 3)
        let chips = field.argumentChips.map(\.frame)
        #expect(chips[0].minX > field.textField.frame.minX)
        #expect(chips[1].minX > chips[0].maxX)
        #expect(chips[2].minX > chips[1].maxX)
    }

    @Test func tabMovesIntoTheChipsAndTypingStaysInOne() throws {
        let (surface, field, recorder) = makeField()
        defer { surface.panel.close() }
        let editor = surface.panel.queryFieldEditor
        editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(field.focusedArgument == 0)
        #expect(!recorder.commands.contains(.complete), "Tab moves into the arguments instead of completing")
        // The chip grows while typing; its text must not be selected and replaced.
        for character in "signature" {
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        #expect(field.argumentValues[0] == "signature")
        #expect(recorder.values[0] == "signature")
        editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(field.focusedArgument == 1)
        let secure = try #require(surface.panel.firstResponder as? NSTextView)
        #expect(secure !== editor, "the secure chip uses AppKit's secure editor")
        secure.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        #expect(field.focusedArgument == 0)
        editor.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        #expect(field.focusedArgument == nil)
        #expect(field.textField.currentEditor() != nil)
    }

    @Test func returnInAChipSubmits() {
        let (surface, field, recorder) = makeField()
        defer { surface.panel.close() }
        field.focusArgument(0)
        surface.panel.queryFieldEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(recorder.commands.contains(.submit([])))
    }

    @Test func aDropdownChipChoosesFromAMenuInThePanel() throws {
        let (surface, field, recorder) = makeField()
        defer { surface.panel.close() }
        field.argumentChips[2].openMenu()
        let menu = try #require(surface.overlay as? DropdownMenuView)
        menu.keyDown(with: try #require(SyntheticEvents.arrow(down: true, in: surface.panel)))
        menu.keyDown(with: try #require(SyntheticEvents.returnKey(in: surface.panel)))
        #expect(field.argumentValues[2] == "work")
        #expect(recorder.values[2] == "work")
    }

    @Test func theBackChevronReportsBack() throws {
        let (surface, field, recorder) = makeField()
        defer { surface.panel.close() }
        field.leading = QueryLeading(glyph: .back, breadcrumb: "Snippets")
        surface.rootView.layoutSubtreeIfNeeded()
        #expect(field.glyphView.accessibilityPerformPress())
        #expect(recorder.commands == [.back])
        let point = field.convert(
            CGPoint(x: field.breadcrumb.frame.midX, y: field.breadcrumb.frame.midY), to: field.superview)
        #expect(field.hitTest(point) === field.glyphView, "the breadcrumb answers a click with Back too")
    }

    @Test func horizontalArrowsReachTheHost() {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        surface.panel.orderFrontRegardless()
        surface.queryField.installEditor()
        let recorder = FieldRecorder()
        recorder.claims = { _ in true }
        surface.queryField.delegate = recorder
        surface.panel.queryFieldEditor.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        surface.panel.queryFieldEditor.doCommand(by: #selector(NSResponder.moveRight(_:)))
        #expect(recorder.commands == [.moveLeft, .moveRight])
    }
}
