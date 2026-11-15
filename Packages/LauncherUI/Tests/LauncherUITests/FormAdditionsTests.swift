import AppKit
import LauncherUITesting
import Testing

@testable import LauncherUI

@Suite(.timeLimit(.minutes(1)))
struct FormAdditionsTests {
    func makeForm(_ items: [FormItem]) -> (surface: LauncherSurface, form: FormView) {
        let surface = TestSupport.makeSurface()
        surface.panel.orderFrontRegardless()
        surface.queryField.installEditor()
        let form = FormView()
        surface.setContent(form, animated: false)
        form.apply(FormContent(items: items))
        return (surface, form)
    }

    @Test func placeholdersAreFound() {
        #expect(
            PlaceholderHighlighter.ranges(in: "Hi {name}, {date}") == [
                NSRange(location: 3, length: 6), NSRange(location: 11, length: 6),
            ])
        #expect(PlaceholderHighlighter.ranges(in: "{} {a\nb} {{x}}") == [NSRange(location: 10, length: 3)])
        #expect(
            PlaceholderHighlighter.clamped(NSRange(location: 3, length: 50), length: 10)
                == NSRange(location: 3, length: 7))
    }

    @Test func aHighlightingFieldColoursPlaceholdersButKeepsItsValue() throws {
        var item = FormItem(id: "text", label: "Text", kind: .text(placeholder: ""), value: .text("Dear {name}"))
        item.highlightsPlaceholders = true
        let (surface, form) = makeForm([item])
        defer { surface.panel.close() }
        form.focus("text")
        let editor = surface.panel.queryFieldEditor
        let layoutManager = try #require(editor.layoutManager)
        let colored = layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: 6, effectiveRange: nil)
        let plain = layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: 1, effectiveRange: nil)
        #expect(colored != nil)
        #expect(plain == nil)
        #expect(form.values["text"] == .text("Dear {name}"))
        #expect(editor.textStorage?.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor != nil)
        // Leaving the field takes the colours off the shared editor.
        surface.panel.makeFirstResponder(nil)
        #expect(layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: 6, effectiveRange: nil) == nil)
    }

    @Test func aRangeCanBeSelectedInAField() {
        let items = [
            FormItem(id: "one", label: "One", kind: .text(placeholder: ""), value: .text("Hello {name}")),
            FormItem(id: "many", label: "Many", kind: .multiline(placeholder: ""), value: .text("Line one\nLine two")),
            FormItem(id: "pin", label: "Pin", kind: .checkbox(label: "Pin")),
        ]
        let (surface, form) = makeForm(items)
        defer { surface.panel.close() }
        #expect(form.selectText(in: "one", range: NSRange(location: 6, length: 6)))
        #expect(surface.panel.queryFieldEditor.selectedRange() == NSRange(location: 6, length: 6))
        #expect(form.focusedID == "one")
        #expect(form.selectText(in: "many", range: NSRange(location: 9, length: 100)))
        let multiline = form.control(for: "many") as? MultilineFormControl
        #expect(multiline?.textView.selectedRange() == NSRange(location: 9, length: 8))
        #expect(!form.selectText(in: "pin", range: NSRange(location: 0, length: 1)))
        #expect(!form.selectText(in: "missing", range: NSRange(location: 0, length: 1)))
    }

    @Test func tagSuggestionsComplete() {
        let suggestions = ["Swift", "SwiftUI", "Rust", "Sweet Potato", "Bread"]
        #expect(TagSuggestions.completion(for: "sw", in: suggestions, excluding: []) == "Swift")
        #expect(TagSuggestions.completion(for: "sw", in: suggestions, excluding: ["Swift"]) == "SwiftUI")
        #expect(TagSuggestions.completion(for: "Swift", in: suggestions, excluding: []) == "SwiftUI")
        #expect(TagSuggestions.completion(for: "", in: suggestions, excluding: []) == nil)
        #expect(TagSuggestions.matches(for: "p", in: suggestions, excluding: []) == ["Sweet Potato"])
        #expect(TagSuggestions.matches(for: "", in: suggestions, excluding: ["Rust"]).count == 4)
    }

    @Test func aTagFieldAddsTheCompletedSuggestion() throws {
        var item = FormItem(id: "tags", label: "Tags", kind: .tags(placeholder: "Add"))
        item.suggestions = ["design", "development"]
        let (surface, form) = makeForm([item])
        defer { surface.panel.close() }
        form.focus("tags")
        let control = try #require(form.control(for: "tags") as? TagFormControl)
        let editor = surface.panel.queryFieldEditor
        editor.insertText("dev", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(control.completion == "development")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(form.values["tags"] == .tags(["development"]))
        #expect(control.field.stringValue.isEmpty)
        editor.insertText("de", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(control.completion == "design")
        editor.doCommand(by: #selector(NSResponder.moveRight(_:)))
        #expect(control.field.stringValue == "design")
        #expect(form.values["tags"] == .tags(["development"]))
    }

    @Test func theApplicationPickerShowsTheChosenApp() throws {
        let apps = [
            MenuOption(id: "com.example.editor", title: "Example Editor", icon: .symbol("pencil")),
            MenuOption(id: "com.example.mail", title: "Example Mail", icon: .symbol("envelope")),
        ]
        let item = FormItem(id: "app", label: "App", kind: .application(placeholder: "Choose an app", apps: apps))
        let (surface, form) = makeForm([item])
        defer { surface.panel.close() }
        #expect(form.values["app"] == .option(nil))
        let control = try #require(form.control(for: "app") as? DropdownFormControl)
        #expect(control.selectedTitle.isEmpty)
        form.apply(
            FormContent(items: [
                FormItem(
                    id: "app", label: "App", kind: .application(placeholder: "Choose an app", apps: apps),
                    value: .option("com.example.mail"))
            ]))
        #expect(control.selectedTitle == "Example Mail")
        #expect(form.values["app"] == .option("com.example.mail"))
        form.apply(
            FormContent(items: [
                FormItem(
                    id: "app", label: "App", kind: .application(placeholder: "Choose an app", apps: apps),
                    value: .option("com.example.other"))
            ]))
        #expect(control.selectedTitle == "com.example.other")
        control.openMenu()
        #expect(surface.overlay is DropdownMenuView)
        surface.dismissOverlay()
    }
}
