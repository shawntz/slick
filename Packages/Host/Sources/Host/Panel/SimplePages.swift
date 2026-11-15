import AppKit
import Kit
import LauncherUI

/// A page for a kind of view the host cannot draw yet: grids, details and forms until they are
/// built. It shows a plain empty state, so a command that pushes one does not crash. Back and
/// Escape leave it as they leave any page.
@MainActor public final class PlaceholderPageController: PageController {
    public let title: String?
    public let contentView = PageContentView()
    private let emptyView = EmptyStateView()

    public init(title: String?) {
        self.title = title
        emptyView.apply(
            EmptyStateContent(
                symbolName: "hammer", title: HostStrings.notBuiltYet, hint: HostStrings.notBuiltYetHint))
        contentView.show(emptyView)
    }

    public var searchPlaceholder: String { "" }
    public var query: String { "" }
    public func pageDidAppear(in host: any PageHost) {}
    public func pageDidDisappear() {}
    public func pageWillClose() {}
    public func queryDidChange(_ text: String) {}
    public func moveSelection(_ move: SelectionMove) -> Bool { false }
    public var target: ActionTarget? { nil }
}

/// A page that asks for one line of text in the search field, such as an alias or a hotkey.
/// Return submits; the closure returns an error message to show, or nil when the page may close.
@MainActor final class PromptPageController: PageController {
    let title: String?
    let searchPlaceholder: String
    let initialQuery: String
    let contentView = PageContentView()
    private let emptyView = EmptyStateView()
    private let symbolName: String
    private let hint: String
    private let submit: (String) -> String?
    private(set) var query: String

    init(
        title: String, placeholder: String, initialText: String, symbolName: String, hint: String,
        submit: @escaping (String) -> String?
    ) {
        self.title = title
        searchPlaceholder = placeholder
        initialQuery = initialText
        query = initialText
        self.symbolName = symbolName
        self.hint = hint
        self.submit = submit
        showHint(hint)
        contentView.show(emptyView)
    }

    func pageDidAppear(in host: any PageHost) {}
    func pageDidDisappear() {}
    func pageWillClose() {}

    func queryDidChange(_ text: String) {
        query = text
    }

    func moveSelection(_ move: SelectionMove) -> Bool { false }
    var target: ActionTarget? { nil }

    func handle(_ command: QueryCommand) -> Bool {
        guard case .submit = command else { return false }
        if let problem = submit(query.trimmingCharacters(in: .whitespaces)) { showHint(problem) }
        return true
    }

    private func showHint(_ text: String) {
        emptyView.apply(EmptyStateContent(symbolName: symbolName, title: title ?? "", hint: text))
    }
}

/// Asks for an item's hotkey with a recorder: the next chord with Command, Control or Option becomes
/// the hotkey, and Delete clears it. Text typed in the search field, such as `opt+cmd+k`, works too
/// and is saved on Return. The closure saves and returns a problem to show, or nil when the page may
/// close.
@MainActor final class HotkeyPromptPageController: PageController {
    static let fieldID = "hotkey"

    let title: String?
    let contentView = PageContentView()
    let form = FormView()
    private(set) var query = ""
    private let hint: String
    private let save: (KeyCombo?) -> String?
    private var item: FormItem

    init(title: String, current: KeyCombo?, hint: String, save: @escaping (KeyCombo?) -> String?) {
        self.title = title
        self.hint = hint
        self.save = save
        item = FormItem(
            id: Self.fieldID, label: HostStrings.hotkeyLabel, kind: .hotkey(placeholder: HostStrings.recordShortcut),
            value: .hotkey(current.map(Self.chord)), info: hint)
        form.apply(FormContent(items: [item]))
        contentView.show(form)
        form.onChange = { [weak self] _, value in
            guard case .hotkey(let chord) = value else { return }
            self?.submit(chord.flatMap(PanelController.keyCombo), clears: chord == nil)
        }
    }

    var searchPlaceholder: String { HostStrings.hotkeyPlaceholder }

    func pageDidAppear(in host: any PageHost) {
        form.onCancel = { [weak self, weak host] in
            guard let self else { return }
            host?.popPage(self)
        }
        form.focus(Self.fieldID)
    }

    func pageDidDisappear() {}
    func pageWillClose() {}

    func queryDidChange(_ text: String) {
        query = text
    }

    func moveSelection(_ move: SelectionMove) -> Bool { false }
    var target: ActionTarget? { nil }

    func handle(_ command: QueryCommand) -> Bool {
        guard case .submit = command else { return false }
        let text = query.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            submit(nil, clears: true)
        } else if let combo = KeyCombo(parsing: text) {
            submit(combo, clears: false)
        } else {
            show(HostStrings.notAHotkey)
        }
        return true
    }

    private func submit(_ combo: KeyCombo?, clears: Bool) {
        guard combo != nil || clears else {
            show(HostStrings.notAHotkey)
            return
        }
        if let problem = save(combo) { show(problem) }
    }

    private func show(_ problem: String) {
        item.error = problem
        form.apply(FormContent(items: [item]))
    }

    /// A Kit key combination as the recorder shows it.
    nonisolated static func chord(_ combo: KeyCombo) -> KeyChord {
        var modifiers: KeyChord.Modifiers = []
        if combo.modifiers.contains(.command) { modifiers.insert(.command) }
        if combo.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if combo.modifiers.contains(.option) { modifiers.insert(.option) }
        if combo.modifiers.contains(.control) { modifiers.insert(.control) }
        return KeyChord(combo.key.name, modifiers)
    }
}
