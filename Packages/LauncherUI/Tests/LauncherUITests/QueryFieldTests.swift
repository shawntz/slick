import AppKit
import LauncherUITesting
import Testing

@testable import LauncherUI

/// Records what the field reports.
final class FieldRecorder: QueryFieldDelegate {
    var texts: [String] = []
    var commands: [QueryCommand] = []
    var claims: (QueryCommand) -> Bool = { _ in true }

    func queryField(_ field: QueryField, didChangeText text: String) { texts.append(text) }

    func queryField(_ field: QueryField, perform command: QueryCommand) -> Bool {
        commands.append(command)
        return claims(command)
    }
}

@Suite struct QueryFieldTests {
    /// A surface with its field editor installed and a recorder attached. Never key.
    func makeField() -> (surface: LauncherSurface, field: QueryField, editor: NSTextView, recorder: FieldRecorder) {
        let surface = TestSupport.makeSurface()
        surface.panel.orderFrontRegardless()
        surface.queryField.installEditor()
        let recorder = FieldRecorder()
        surface.queryField.delegate = recorder
        return (surface, surface.queryField, surface.panel.queryFieldEditor, recorder)
    }

    @Test func theFieldUsesTheTunedTextKit1Editor() {
        let (surface, field, editor, _) = makeField()
        defer { surface.panel.close() }
        #expect(field.textField.currentEditor() === editor)
        #expect(editor.textLayoutManager == nil)
        #expect(editor.layoutManager != nil)
        #expect(editor.isAutomaticSpellingCorrectionEnabled == false)
    }

    @Test func typingReportsTheText() {
        let (surface, _, editor, recorder) = makeField()
        defer { surface.panel.close() }
        editor.insertText("ab", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(recorder.texts == ["ab"])
    }

    @Test func composingTextDoesNotFireAQuery() {
        let (surface, field, editor, recorder) = makeField()
        defer { surface.panel.close() }
        editor.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setMarkedText(
            "ni", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(field.hasMarkedText)
        #expect(recorder.texts == ["a"])
        editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!field.hasMarkedText)
        #expect(recorder.texts == ["a", "a你"])
    }

    @Test func navigationKeysBecomeCommands() {
        let (surface, _, editor, recorder) = makeField()
        defer { surface.panel.close() }
        for selector in [
            #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)),
            #selector(NSResponder.insertTab(_:)),
            #selector(NSResponder.insertBacktab(_:)), #selector(NSResponder.moveToEndOfDocument(_:)),
        ] {
            editor.doCommand(by: selector)
        }
        #expect(recorder.commands == [.moveDown, .moveUp, .complete, .completeBackward, .moveToNextSection])
    }

    @Test func deleteGoesBackOnlyWhenTheQueryIsEmpty() {
        let (surface, field, editor, recorder) = makeField()
        defer { surface.panel.close() }
        editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(recorder.commands == [.deleteOnEmpty])
        editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(recorder.commands == [.deleteOnEmpty])
        #expect(field.text.isEmpty)
    }

    @Test func returnKeepsTheEditorInstalled() {
        let (surface, field, editor, recorder) = makeField()
        defer { surface.panel.close() }
        recorder.claims = { _ in false }
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(recorder.commands == [.submit([])])
        #expect(field.textField.currentEditor() === editor)
    }

    @Test func commandChordsGoToTheHostFirst() throws {
        let (surface, _, _, recorder) = makeField()
        defer { surface.panel.close() }
        recorder.claims = { command in command == .chord(KeyChord("k", .command)) }
        let commandK = try #require(SyntheticEvents.key("k", modifiers: .command, in: surface.panel))
        #expect(surface.panel.performKeyEquivalent(with: commandK))
        let commandReturn = try #require(SyntheticEvents.returnKey(modifiers: .command, in: surface.panel))
        _ = surface.panel.performKeyEquivalent(with: commandReturn)
        #expect(recorder.commands == [.chord(KeyChord("k", .command)), .submit(.command)])
    }

    @Test func unclaimedEditChordsReachTheMenu() throws {
        let (surface, _, _, recorder) = makeField()
        defer { surface.panel.close() }
        recorder.claims = { _ in false }
        let commandA = try #require(SyntheticEvents.key("a", modifiers: .command, in: surface.panel))
        #expect(surface.queryField.handleKeyEquivalent(commandA) == false)
    }

    @Test func theGhostFollowsTheTypedText() {
        let (surface, field, editor, _) = makeField()
        defer { surface.panel.close() }
        field.ghostText = "ora Notes"
        #expect(field.ghostFrame == nil, "no ghost without typed text")
        editor.insertText("Aur", replacementRange: NSRange(location: NSNotFound, length: 0))
        let short = field.ghostFrame
        editor.insertText("ora", replacementRange: NSRange(location: NSNotFound, length: 0))
        let long = field.ghostFrame
        #expect(short != nil && long != nil)
        #expect((long?.minX ?? 0) > (short?.minX ?? 0))
        editor.setMarkedText(
            "n", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(field.ghostFrame == nil, "the ghost hides while composing")
    }
}

@Suite struct KeyChordTests {
    @Test func onlyKeyEventsMakeChords() throws {
        _ = NSApplication.shared
        let mouse = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        #expect(KeyChord(event: mouse) == nil)
        let window = NSWindow(
            contentRect: TestSupport.offscreen, styleMask: [.borderless], backing: .buffered, defer: true)
        let commandK = try #require(SyntheticEvents.key("k", modifiers: .command, in: window))
        #expect(KeyChord(event: commandK) == KeyChord("k", .command))
    }
}
