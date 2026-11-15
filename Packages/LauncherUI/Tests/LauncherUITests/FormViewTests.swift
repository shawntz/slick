import AppKit
import LauncherUITesting
import Testing

@testable import LauncherUI

@Suite struct FormViewTests {
    /// A surface showing the synthetic form, ordered in off screen and never key.
    func makeForm() -> (surface: LauncherSurface, form: FormView) {
        let surface = TestSupport.makeSurface()
        surface.panel.orderFrontRegardless()
        surface.queryField.installEditor()
        let form = FormView()
        surface.setContent(form, animated: false)
        form.apply(SyntheticComponents.form())
        return (surface, form)
    }

    @Test func focusingAFieldShowsItsRingAndReportsIt() throws {
        let (surface, form) = makeForm()
        defer { surface.panel.close() }
        form.focus("link")
        #expect(form.focusedID == "link")
        let control = try #require(form.control(for: "link"))
        #expect(control.isFocused)
        #expect((control.layer?.borderWidth ?? 0) > 0)
        form.focus("name")
        #expect(form.focusedID == "name")
        #expect(!control.isFocused)
        #expect(control.layer?.borderWidth == 0)
    }
}

@Suite struct FormBehaviourTests {
    func makeForm() -> (surface: LauncherSurface, form: FormView) {
        FormViewTests().makeForm()
    }

    @Test func valuesStartFromTheContentAndReportEdits() {
        let (surface, form) = makeForm()
        defer { surface.panel.close() }
        #expect(form.values["name"] == .text("Team notes"))
        #expect(form.values["pin"] == .bool(true))
        #expect(form.values["tags"] == .tags(["work", "sprint"]))
        #expect(form.values["hotkey"] == .hotkey(KeyChord("n", [.option, .command])))
        var changes: [String] = []
        form.onChange = { id, _ in changes.append(id) }
        form.focus("name")
        // Focusing a field selects its text, as AppKit does, so typing replaces it.
        surface.panel.queryFieldEditor.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(form.values["name"] == .text("!"))
        #expect(changes == ["name"])
    }

    @Test func tabWalksTheFieldsInOrderAndWraps() {
        let (surface, form) = makeForm()
        defer { surface.panel.close() }
        form.focus("name")
        var order: [String] = []
        for _ in 0..<11 {
            surface.panel.selectKeyView(
                following: surface.panel.firstResponder.flatMap { responder in
                    (responder as? NSTextView)?.delegate as? NSView ?? responder as? NSView
                } ?? form)
            order.append(form.focusedID ?? "none")
        }
        #expect(order.first == "link")
        #expect(order.contains("browser"))
        #expect(order.contains("hotkey"))
        #expect(!order.contains("separator"))
        #expect(order.last == "link", "after the last field Tab wraps to the first")
    }

    @Test func aSecureFieldKeepsAppKitsSecureEditor() throws {
        let (surface, form) = makeForm()
        defer { surface.panel.close() }
        form.focus("token")
        let editor = try #require(surface.panel.firstResponder as? NSTextView)
        #expect(editor !== surface.panel.queryFieldEditor)
    }

    @Test func aHostUpdateKeepsWhatTheUserTyped() {
        let (surface, form) = makeForm()
        defer { surface.panel.close() }
        form.focus("name")
        surface.panel.queryFieldEditor.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        let typed = form.values["name"]
        var content = SyntheticComponents.form()
        content.items[1].error = nil
        form.apply(content)
        #expect(form.values["name"] == typed, "the host's value did not change, so the typed text stays")
        content.items[0].value = .text("Renamed")
        form.apply(content)
        #expect(form.values["name"] == .text("Renamed"))
    }

    @Test func errorsAddAMessageLine() {
        let (surface, form) = makeForm()
        defer { surface.panel.close() }
        let withError = form.layoutModel.rows[1]
        #expect(withError.message != nil)
        #expect(form.layoutModel.rows[0].message == nil)
    }

    @Test func theHotkeyRecorderRecordsChordsAndClears() throws {
        let (surface, form) = makeForm()
        defer { surface.panel.close() }
        form.focus("hotkey")
        let recorder = try #require(form.control(for: "hotkey") as? HotkeyRecorderField)
        #expect(surface.panel.firstResponder === recorder)
        let chord = try #require(SyntheticEvents.key("j", modifiers: [.control, .option], in: surface.panel))
        #expect(surface.panel.performKeyEquivalent(with: chord))
        #expect(form.values["hotkey"] == .hotkey(KeyChord("j", [.control, .option])))
        let plain = try #require(SyntheticEvents.key("j", in: surface.panel))
        #expect(!recorder.record(plain), "a key without Command, Control or Option is not a shortcut")
        recorder.keyDown(with: try #require(SyntheticEvents.delete(in: surface.panel)))
        #expect(form.values["hotkey"] == .hotkey(nil))
    }

    @Test func tagsAreAddedWithReturnAndRemovedWithDelete() throws {
        let (surface, form) = makeForm()
        defer { surface.panel.close() }
        form.focus("tags")
        let editor = surface.panel.queryFieldEditor
        editor.insertText("q4", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(form.values["tags"] == .tags(["work", "sprint", "q4"]))
        editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(form.values["tags"] == .tags(["work", "sprint"]))
        editor.insertText("a, b,", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(form.values["tags"] == .tags(["work", "sprint", "a", "b"]))
    }

    @Test func commandReturnSubmitsAndEscapeCancels() throws {
        let (surface, form) = makeForm()
        defer { surface.panel.close() }
        var events: [String] = []
        form.onSubmit = { events.append("submit") }
        form.onCancel = { events.append("cancel") }
        form.focus("name")
        #expect(
            surface.panel.performKeyEquivalent(
                with: try #require(SyntheticEvents.returnKey(modifiers: .command, in: surface.panel))))
        surface.panel.queryFieldEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(events == ["submit", "cancel"])
    }
}
