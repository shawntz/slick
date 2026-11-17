import Foundation
import Kit
import KitHosting
import LauncherUI
import Observation

/// The appearance pane: whether the launcher draws light, dark or as the system does, the theme,
/// its values, a copy of it as a new theme, import, export and, for a built-in theme, a reset.
///
/// Every control changes the launcher. An edit changes ``draft``, which the preview draws at once,
/// and a moment after the last edit, ``commitDelay``, the model hands the draft to the theme store,
/// which restyles the panel and keeps the theme's file. A slider or color drag therefore restyles
/// the hidden panel and writes the file once it pauses, not on every tick. ``flush()`` commits at
/// once, before anything else changes the store, and when the pane goes away.
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
    @ObservationIgnored private let tasks = TaskBag()
    /// The commit that waits for edits to pause.
    @ObservationIgnored private var pendingCommit: Task<Void, Never>?
    /// True while the model hands the draft to the store, so the store's change is not taken for
    /// one made elsewhere.
    @ObservationIgnored private var isCommitting = false
    /// How long after the last edit the draft reaches the store.
    @ObservationIgnored var commitDelay: Duration = .milliseconds(100)
    /// The clock that measures ``commitDelay``. A test sets a fake one to say when the time passed.
    @ObservationIgnored var clock: any ClockService = SystemClock()
    private let revision = Revision()

    /// The theme as edited, which the preview draws. It reaches the store a moment after each edit.
    private(set) var draft: Theme

    init(context: SettingsContext) {
        self.context = context
        draft = context.dependencies.themes.current
        observer = context.dependencies.themes.addObserver { [weak self] changes in
            self?.storeChanged(changes)
        }
        tasks.follow([HostSettings.appearance.erased], in: context.general, bumping: revision)
    }

    isolated deinit {
        pendingCommit?.cancel()
        if let observer { context.dependencies.themes.removeObserver(observer) }
    }

    private var store: ThemeStore { context.dependencies.themes }

    /// A change the model did not make, such as a selection made in onboarding, drops what waits
    /// to be committed and shows the store's theme.
    private func storeChanged(_ changes: ThemeStore.Changes) {
        if changes.contains(.current), !isCommitting { adopt(store.current) }
        revision.bump()
    }

    /// Shows a theme from the store and drops the commit that waits.
    private func adopt(_ theme: Theme) {
        pendingCommit?.cancel()
        pendingCommit = nil
        if draft != theme { draft = theme }
    }

    /// Changes the draft and commits it a moment later.
    private func edit(_ change: (inout Theme) -> Void) {
        var theme = draft
        change(&theme)
        guard theme != draft else { return }
        draft = theme
        pendingCommit?.cancel()
        let delay = commitDelay
        let clock = clock
        pendingCommit = Task { [weak self] in
            try? await clock.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            pendingCommit = nil
            commit()
        }
    }

    /// Commits the draft now, without waiting for the edits to pause.
    func flush() {
        pendingCommit?.cancel()
        pendingCommit = nil
        commit()
    }

    /// Hands the draft to the store for the selected theme, which applies it to the launcher and
    /// keeps it. Nothing happens when the store has it already. A file that cannot be written shows
    /// a failure toast, and the draft stays: the launcher shows it until the store reads the folder
    /// again.
    private func commit() {
        let name = store.selectedName
        guard let stored = store.theme(named: name), stored.theme != draft else { return }
        isCommitting = true
        defer {
            isCommitting = false
            revision.bump()
        }
        do {
            try store.update(draft, for: name)
        } catch ThemeStoreError.unreadable(let file, _) {
            // The store left alone a file it could not read. The line under the theme picker says
            // why it was skipped, so this says what to do.
            context.toasts.show(
                .failure(
                    "Could not save the theme",
                    message: "\(Brand.name) won't write over \(file.lastPathComponent) until you fix or remove it."))
        } catch {
            showFailure("Could not save the theme", error)
        }
    }

    /// A failure toast that says what failed, with the error's own words under it when it has some,
    /// such as the file system's reason a theme file could not be written.
    private func showFailure(_ title: String, _ error: any Error) {
        var message = (error as? any LocalizedError)?.errorDescription
        if message == nil, (error as NSError).domain == NSCocoaErrorDomain {
            message = (error as NSError).localizedDescription
        }
        context.toasts.show(.failure(title, message: message))
    }

    // MARK: Appearance

    /// Whether the launcher draws light, dark or as the system does. The preview draws in it too.
    var appearance: HostSettings.Appearance {
        get {
            revision.track()
            return context.general[HostSettings.appearance]
        }
        set {
            context.general[HostSettings.appearance] = newValue
            revision.bump()
        }
    }

    /// Which appearance the preview shows: nil follows the window, as the launcher follows the
    /// system.
    var previewDark: Bool? {
        switch appearance {
        case .system: nil
        case .light: false
        case .dark: true
        }
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

    /// True while the selected theme is built in and differs from the one that ships, counting an
    /// edit that waits to be committed.
    var isCustomized: Bool {
        revision.track()
        guard let shipped = ThemeStore.builtInTheme(named: store.selectedName) else { return false }
        return draft != shipped.theme
    }

    /// What the selected theme is, in a sentence, such as where Glass's text falls short. Empty
    /// for a theme of the user's own. A built-in theme the user changed says so instead, because
    /// the sentence describes the theme as it ships.
    var summary: String {
        revision.track()
        let name = store.selectedName
        if isCustomized { return "You changed \(name). Reset to Default undoes your changes." }
        return store.theme(named: name)?.summary ?? ""
    }

    /// Selects a theme for the panel and stores the choice. An edit that waits is committed to the
    /// theme that was selected first.
    func select(_ name: String) {
        flush()
        guard store.select(name) else { return }
        context.general[HostSettings.themeName] = store.selectedName
        adopt(store.current)
        revision.bump()
    }

    /// Reads the theme folder again, as when the pane appears.
    func reload() {
        flush()
        store.reload()
        revision.bump()
    }

    /// Puts the selected built-in theme back as it ships, after the user confirms.
    func resetToDefault() async {
        flush()
        let name = store.selectedName
        guard isBuiltIn, isCustomized else { return }
        let confirmed = await context.confirmations.ask(
            Confirmation(
                "Reset \(name)?", message: "Your changes to \(name) are removed. This cannot be undone.",
                confirmTitle: "Reset", isDestructive: true))
        guard confirmed else { return }
        do {
            try store.reset(name)
        } catch {
            showFailure("Could not reset the theme", error)
        }
        adopt(store.current)
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

    /// Copies the selected theme as it is now under a new name, as a theme of the user's own, and
    /// selects the copy. Returns false when a theme already has the name or it cannot be a file
    /// name, so the copy never replaces a theme.
    @discardableResult
    func saveAsNew(named name: String) -> Bool {
        flush()
        if let existing = store.theme(named: name.trimmingCharacters(in: .whitespacesAndNewlines)),
            !existing.isBuiltIn
        {
            context.toasts.show(
                .failure("You already have a theme named \(existing.name). Save it under another name."))
            return false
        }
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
        flush()
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
        flush()
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

    /// Asks where to save and writes the selected theme there, as it is now.
    func exportTheme() async {
        flush()
        let name = selectedName
        let request = SaveDialogRequest(title: "Export Theme", suggestedName: name + ".json", allowedTypes: ["json"])
        guard let url = await context.services.fileDialogs.chooseSaveLocation(request) else { return }
        do {
            try store.exportTheme(named: name, to: url)
            context.toasts.show(.success("Exported \(url.lastPathComponent)"))
        } catch {
            context.toasts.show(error, title: "Could not export the theme")
        }
    }

    // MARK: Edits

    var clarity: Double {
        get { draft.clarity }
        set { edit { $0.clarity = Self.clamp(newValue, Limits.clarity) } }
    }

    var lensStyle: LensMetrics.Style {
        get { draft.lens.style }
        set { edit { $0.lens.style = newValue } }
    }

    /// Regular glass, which frosts what is behind it, or clear glass, the most translucent.
    var glassStyle: GlassStyle {
        get { draft.panel.glassStyle }
        set { edit { $0.panel.glassStyle = newValue } }
    }

    /// One piece of glass, or the search field apart from the results.
    var layout: PanelLayout {
        get { draft.panel.layout }
        set { edit { $0.panel.layout = newValue } }
    }

    func glassTint(dark: Bool) -> ThemeColor {
        draft.glassTint(dark: dark)
    }

    /// Sets the tint's colour and keeps its strength.
    func setGlassTintColor(red: Double, green: Double, blue: Double, dark: Bool) {
        edit { theme in
            let strength = theme.glassTint(dark: dark).alpha
            theme.setGlassTint(ThemeColor(red: red, green: green, blue: blue, alpha: strength), dark: dark)
        }
    }

    /// The tint's alpha: how strongly the glass leans toward its colour.
    func tintStrength(dark: Bool) -> Double {
        draft.glassTint(dark: dark).alpha
    }

    func setTintStrength(_ strength: Double, dark: Bool) {
        edit { theme in
            var tint = theme.glassTint(dark: dark)
            tint.alpha = Self.clamp(strength, Limits.tintStrength)
            theme.setGlassTint(tint, dark: dark)
        }
    }

    /// True while the accent follows the system's.
    var followsSystemAccent: Bool {
        get { draft.accent == nil }
        set {
            edit { $0.setAccent(newValue ? nil : ($0.accent ?? ThemeColor(red: 0.04, green: 0.43, blue: 0.54))) }
        }
    }

    var accent: ThemeColor? {
        get { draft.accent }
        set { edit { $0.setAccent(newValue) } }
    }

    var titleSize: Double {
        get { draft.titleSize }
        set { edit { $0.titleSize = Self.clamp(newValue, Limits.titleSize) } }
    }

    var subtitleSize: Double {
        get { draft.subtitleSize }
        set { edit { $0.subtitleSize = Self.clamp(newValue, Limits.subtitleSize) } }
    }

    var querySize: Double {
        get { draft.querySize }
        set { edit { $0.querySize = Self.clamp(newValue, Limits.querySize) } }
    }

    var rowHeight: Double {
        get { draft.rowHeight }
        set { edit { $0.rowHeight = Self.clamp(newValue, Limits.rowHeight).rounded() } }
    }

    var cornerRadius: Double {
        get { draft.panel.cornerRadius }
        set { edit { $0.panel.cornerRadius = Self.clamp(newValue, Limits.cornerRadius).rounded() } }
    }

    var lensCornerRadius: Double {
        get { draft.lens.cornerRadius }
        set { edit { $0.lens.cornerRadius = Self.clamp(newValue, Limits.lensRadius).rounded() } }
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
