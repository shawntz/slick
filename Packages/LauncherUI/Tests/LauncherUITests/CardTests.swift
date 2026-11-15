import AppKit
import LauncherUITesting
import Testing

@testable import LauncherUI

@Suite struct ActionCardContentTests {
    @Test func filteringRanksPrefixThenWordThenSubstringAndFlattens() {
        let content = ActionCardContent(sections: [
            ActionSection(items: [
                ActionItem(id: "a", title: "Reveal in Finder"), ActionItem(id: "b", title: "Find Text"),
            ]),
            ActionSection(
                title: "More", items: [ActionItem(id: "c", title: "Refind"), ActionItem(id: "d", title: "Copy")]),
        ])
        let filtered = content.filtered(by: "fin")
        #expect(filtered.sections.count == 1)
        #expect(filtered.sections[0].title == nil)
        #expect(filtered.sections[0].items.map(\.id) == ["b", "a", "c"])
        #expect(filtered.sections[0].items[0].titleHighlights == [HighlightRange(location: 0, length: 3)])
        #expect(content.filtered(by: "") == content)
    }
}

@Suite struct OverlayTests {
    /// A surface with its query field focused, ordered in off screen and never key.
    func makeSurface() -> LauncherSurface {
        let surface = TestSupport.makeSurface()
        surface.panel.orderFrontRegardless()
        surface.queryField.installEditor()
        surface.accessibilityOverride = DisplayAccessibility(reduceMotion: true)
        let list = ResultListView()
        surface.setContent(list, animated: false)
        list.apply(SyntheticCatalog().rootContent())
        return surface
    }

    func command(_ selector: Selector, in surface: LauncherSurface) {
        surface.panel.queryFieldEditor.doCommand(by: selector)
    }

    @Test func theActionCardFiltersMovesRunsAndDims() throws {
        let surface = makeSurface()
        defer { surface.panel.close() }
        let card = ActionCardView(content: SyntheticComponents.actions)
        var ran: [String] = []
        card.onActivate = { ran.append($0.id) }
        surface.present(card)
        #expect(surface.overlay === card)
        #expect(card.filterField.currentEditor() != nil, "the filter field takes the keyboard")
        #expect(Double(surface.content?.alphaValue ?? 1) == Theme.standard.card.dimAlpha)
        // It sits in the bottom-right corner above the action bar.
        let glassWidth = CGFloat(Theme.standard.panel.width)
        #expect(card.frame.maxX == glassWidth - CGFloat(Theme.standard.card.margin))

        let editor = surface.panel.queryFieldEditor
        editor.insertText("hot", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(card.selectedItem?.id == "hotkey")
        command(#selector(NSResponder.insertNewline(_:)), in: surface)
        #expect(ran == ["hotkey"])

        command(#selector(NSResponder.cancelOperation(_:)), in: surface)
        #expect(card.query.isEmpty, "the first Escape clears the filter")
        #expect(surface.overlay === card)
        command(#selector(NSResponder.moveDown(_:)), in: surface)
        #expect(card.selectedItem?.id == "reveal")
        command(#selector(NSResponder.cancelOperation(_:)), in: surface)
        #expect(surface.overlay == nil)
        #expect(Double(surface.content?.alphaValue ?? 0) == 1)
        #expect(surface.queryField.textField.currentEditor() != nil, "the query field gets the keyboard back")
    }

    @Test func theActionCardKeepsItsHeightWhileFiltering() {
        let surface = makeSurface()
        defer { surface.panel.close() }
        let card = ActionCardView(content: SyntheticComponents.actions)
        surface.present(card)
        let frame = card.frame
        surface.panel.queryFieldEditor.insertText("hot", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(card.selectedItem?.id == "hotkey")
        #expect(card.frame == frame, "the filter field stays put and the glass is not resized")
    }

    @Test func theConfirmCardAnswersReturnAndEscape() throws {
        let surface = makeSurface()
        defer { surface.panel.close() }
        var answers: [String] = []
        let ask = {
            let card = ConfirmCardView(
                content: ConfirmContent(title: "Delete?", confirmTitle: "Delete", isDestructive: true))
            card.onConfirm = { answers.append("confirm") }
            card.onCancel = { answers.append("cancel") }
            surface.present(card)
            return card
        }
        var card = ask()
        #expect(surface.panel.firstResponder === card)
        #expect(card.confirmButton.role == .destructive)
        card.keyDown(with: try #require(SyntheticEvents.returnKey(in: surface.panel)))
        card = ask()
        card.keyDown(with: try #require(SyntheticEvents.escape(in: surface.panel)))
        #expect(answers == ["confirm", "cancel"])
        #expect(surface.overlay == nil)
    }

    @Test func aMenuChoosesAndHandsFocusBack() throws {
        let surface = makeSurface()
        defer { surface.panel.close() }
        surface.queryField.filter = QueryFilter(
            options: SyntheticComponents.filterOptions, selectedID: "all", label: "Type")
        var chosen: [String] = []
        let recorder = FilterRecorder { chosen.append($0.id) }
        surface.queryField.delegate = recorder
        surface.rootView.layoutSubtreeIfNeeded()
        surface.queryField.openFilterMenu()
        let menu = try #require(surface.overlay as? DropdownMenuView)
        #expect(surface.panel.firstResponder === menu)
        menu.keyDown(with: try #require(SyntheticEvents.arrow(down: true, in: surface.panel)))
        menu.keyDown(with: try #require(SyntheticEvents.returnKey(in: surface.panel)))
        #expect(chosen == ["text"])
        #expect(surface.queryField.filter?.selectedID == "text")
        #expect(surface.overlay == nil)
        #expect(surface.queryField.textField.currentEditor() != nil)
    }

    @Test func aShortGlassGrowsToHoldACard() {
        let surface = makeSurface()
        defer { surface.panel.close() }
        surface.setContent(nil, animated: false)
        #expect(surface.contentHeight == 0)
        surface.present(ActionCardView(content: SyntheticComponents.actions))
        #expect(surface.contentHeight > 0)
        surface.dismissOverlay()
        #expect(surface.contentHeight == 0)
    }

    @Test func aClickOutsideTheCardClosesIt() throws {
        let surface = makeSurface()
        defer { surface.panel.close() }
        surface.present(ActionCardView(content: SyntheticComponents.actions))
        let shield = try #require(surface.shield.superview != nil ? surface.shield : nil)
        shield.mouseDown(
            with: try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                    context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1)))
        #expect(surface.overlay == nil)
    }
}

/// Records filter choices.
final class FilterRecorder: QueryFieldDelegate {
    let onChoose: (MenuOption) -> Void
    init(_ onChoose: @escaping (MenuOption) -> Void) { self.onChoose = onChoose }
    func queryField(_ field: QueryField, didChangeText text: String) {}
    func queryField(_ field: QueryField, perform command: QueryCommand) -> Bool { false }
    func queryField(_ field: QueryField, didChooseFilter option: MenuOption) { onChoose(option) }
}
