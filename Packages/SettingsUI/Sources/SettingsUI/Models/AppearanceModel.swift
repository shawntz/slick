import Foundation
import Kit
import KitHosting
import LauncherUI
import Observation

/// The appearance pane: pick a theme, edit it live in the preview, save it as a theme of the
/// user's own, import, export and revert.
///
/// Edits change ``draft``, which the preview draws at once. The panel keeps the stored theme until
/// the user saves: ``save()`` writes over a user theme, and a built-in theme is saved under a new
/// name with ``saveAsNew(named:)``.
@Observable final class AppearanceModel {
    /// The ranges the pane's sliders and steppers allow.
    enum Limits {
        static let clarity = 0.0...2.0
        static let tintStrength = 0.0...0.9
        static let titleSize = 11.0...20.0
        static let subtitleSize = 10.0...17.0
        static let querySize = 16.0...30.0
        static let rowHeight = 32.0...60.0
        static let cornerRadius = 8.0...36.0
        static let lensRadius = 4.0...24.0
    }

    @ObservationIgnored private let context: SettingsContext
    @ObservationIgnored private var observer: ThemeStore.ObserverID?
    private let revision = Revision()

    /// The theme as edited, which the preview draws.
    var draft: Theme
    /// Which appearance the preview shows. Nil follows the window.
    var previewDark: Bool?

    init(context: SettingsContext) {
        self.context = context
        draft = context.dependencies.themes.current
        draftBase = context.dependencies.themes.current
        observer = context.dependencies.themes.addObserver { [weak self] changes in
            self?.storeChanged(changes)
        }
    }

    isolated deinit {
        if let observer { context.dependencies.themes.removeObserver(observer) }
    }

    private var store: ThemeStore { context.dependencies.themes }

    private func storeChanged(_ changes: ThemeStore.Changes) {
        if changes.contains(.current), !isEdited(against: draftBase) { draft = store.current }
        draftBase = store.current
        revision.bump()
    }

    /// The stored theme the draft started from.
    @ObservationIgnored private var draftBase: Theme?

    private func isEdited(against base: Theme?) -> Bool {
        draft != (base ?? store.current)
    }

    // MARK: Themes

    /// Every theme: the built-in ones, then the user's.
    var themes: [NamedTheme] {
        revision.track()
        return store.themes
    }

    /// Theme files that were skipped, with the reason.
    var problems: [ThemeFileProblem] {
        revision.track()
        return store.problems
    }

    var selectedName: String {
        revision.track()
        return store.selectedName
    }

    var isBuiltIn: Bool {
        revision.track()
        return store.theme(named: store.selectedName)?.isBuiltIn ?? true
    }

    /// What the selected theme is, in a sentence, such as where Glass's text falls short. Empty
    /// for a theme of the user's own.
    var summary: String {
        revision.track()
        return store.theme(named: store.selectedName)?.summary ?? ""
    }

    /// True when the draft differs from the stored theme.
    var isEdited: Bool {
        revision.track()
        return draft != store.current
    }

    /// Selects a theme for the panel and stores the choice. Unsaved edits are dropped.
    func select(_ name: String) {
        guard store.select(name) else { return }
        context.general[HostSettings.themeName] = store.selectedName
        draft = store.current
        draftBase = store.current
        revision.bump()
    }

    /// Reads the theme folder again, as when the pane appears.
    func reload() {
        store.reload()
        revision.bump()
    }

    /// Drops the edits.
    func revert() {
        draft = store.current
    }

    /// Saves the edits over the selected user theme.
    func save() {
        guard !isBuiltIn else { return }
        do {
            try store.save(draft, as: store.selectedName)
            draftBase = store.current
            context.toasts.show(.success("Saved \(store.selectedName)"))
        } catch {
            context.toasts.show(error, title: "Could not save the theme")
        }
        revision.bump()
    }

    /// A name for a new theme that no theme has yet, such as "Ocean Copy 2".
    var suggestedNewName: String {
        let base = selectedName + " Copy"
        var name = base
        var number = 2
        while store.theme(named: name) != nil {
            name = base + " " + String(number)
            number += 1
        }
        return name
    }

    /// Saves the draft as a new user theme and selects it. Returns false when the name is taken
    /// by a built-in theme or cannot be a file name.
    @discardableResult
    func saveAsNew(named name: String) -> Bool {
        do {
            try store.save(draft, as: name)
            select(name.trimmingCharacters(in: .whitespacesAndNewlines))
            context.toasts.show(.success("Saved \(store.selectedName)"))
            return true
        } catch {
            context.toasts.show(error, title: "Could not save the theme")
            return false
        }
    }

    /// Deletes a user theme. Standard takes over when it was selected.
    func delete(_ name: String) async {
        let confirmed = await context.confirmations.ask(
            Confirmation(
                "Delete \(name)?", message: "The theme file is removed. This cannot be undone.",
                confirmTitle: "Delete", isDestructive: true))
        guard confirmed else { return }
        do {
            let wasSelected = store.selectedName == name
            try store.delete(name)
            if wasSelected { select(ThemeStore.standardName) }
        } catch {
            context.toasts.show(error, title: "Could not delete the theme")
        }
        revision.bump()
    }

    /// Asks for a theme file and adds it as a user theme, then selects it.
    func importTheme() async {
        let request = OpenDialogRequest(title: "Import Theme", allowedTypes: ["json"])
        guard let url = await context.services.fileDialogs.chooseFiles(request).first else { return }
        do {
            let name = try store.importTheme(from: url)
            select(name)
            context.toasts.show(.success("Imported \(name)"))
        } catch {
            context.toasts.show(error, title: "Could not import the theme")
        }
        revision.bump()
    }

    /// Asks where to save and writes the selected theme there, with the edits when there are any.
    func exportTheme() async {
        let name = selectedName
        let request = SaveDialogRequest(title: "Export Theme", suggestedName: name + ".json", allowedTypes: ["json"])
        guard let url = await context.services.fileDialogs.chooseSaveLocation(request) else { return }
        do {
            if isEdited {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try encoder.encode(draft).write(to: url, options: .atomic)
            } else {
                try store.exportTheme(named: name, to: url)
            }
            context.toasts.show(.success("Exported \(url.lastPathComponent)"))
        } catch {
            context.toasts.show(error, title: "Could not export the theme")
        }
    }

    // MARK: Edits

    var clarity: Double {
        get { draft.clarity }
        set { draft.clarity = Self.clamp(newValue, Limits.clarity) }
    }

    var lensStyle: LensMetrics.Style {
        get { draft.lens.style }
        set { draft.lens.style = newValue }
    }

    /// Regular glass, which frosts what is behind it, or clear glass, the most translucent.
    var glassStyle: GlassStyle {
        get { draft.panel.glassStyle }
        set { draft.panel.glassStyle = newValue }
    }

    /// One piece of glass, or the search field apart from the results.
    var layout: PanelLayout {
        get { draft.panel.layout }
        set { draft.panel.layout = newValue }
    }

    func glassTint(dark: Bool) -> ThemeColor {
        draft.glassTint(dark: dark)
    }

    /// Sets the tint's colour and keeps its strength.
    func setGlassTintColor(red: Double, green: Double, blue: Double, dark: Bool) {
        let strength = draft.glassTint(dark: dark).alpha
        draft.setGlassTint(ThemeColor(red: red, green: green, blue: blue, alpha: strength), dark: dark)
    }

    /// The tint's alpha: how strongly the glass leans toward its colour.
    func tintStrength(dark: Bool) -> Double {
        draft.glassTint(dark: dark).alpha
    }

    func setTintStrength(_ strength: Double, dark: Bool) {
        var tint = draft.glassTint(dark: dark)
        tint.alpha = Self.clamp(strength, Limits.tintStrength)
        draft.setGlassTint(tint, dark: dark)
    }

    /// True while the accent follows the system's.
    var followsSystemAccent: Bool {
        get { draft.accent == nil }
        set { draft.setAccent(newValue ? nil : (draft.accent ?? ThemeColor(red: 0.04, green: 0.43, blue: 0.54))) }
    }

    var accent: ThemeColor? {
        get { draft.accent }
        set { draft.setAccent(newValue) }
    }

    var titleSize: Double {
        get { draft.titleSize }
        set { draft.titleSize = Self.clamp(newValue, Limits.titleSize) }
    }

    var subtitleSize: Double {
        get { draft.subtitleSize }
        set { draft.subtitleSize = Self.clamp(newValue, Limits.subtitleSize) }
    }

    var querySize: Double {
        get { draft.querySize }
        set { draft.querySize = Self.clamp(newValue, Limits.querySize) }
    }

    var rowHeight: Double {
        get { draft.rowHeight }
        set { draft.rowHeight = Self.clamp(newValue, Limits.rowHeight).rounded() }
    }

    var cornerRadius: Double {
        get { draft.panel.cornerRadius }
        set { draft.panel.cornerRadius = Self.clamp(newValue, Limits.cornerRadius).rounded() }
    }

    var lensCornerRadius: Double {
        get { draft.lens.cornerRadius }
        set { draft.lens.cornerRadius = Self.clamp(newValue, Limits.lensRadius).rounded() }
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
