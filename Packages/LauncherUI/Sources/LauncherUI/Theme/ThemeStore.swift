import Foundation

/// The themes the user can pick and the one in use.
///
/// It lists the built-in themes and the user's themes, which are JSON files in a folder it is given,
/// one ``Theme`` per file, named by the file name without `.json`. A file named after a built-in
/// theme, such as `Standard.json`, holds the user's changes to that theme, and the store lists the
/// changed version in its place. It selects one by name, sets a theme's values with
/// ``update(_:for:)``, puts a built-in theme back as it ships with ``reset(_:)``, saves a theme
/// under a new name as a user theme, imports and exports theme files, and tells observers when
/// anything changed. The panel observes it to restyle, and the settings window to redraw its list.
///
/// Scanning and saving read and write files on the calling thread. Make the store at launch and
/// change it from settings, never on the summon or keystroke path. A file that does not decode as a
/// theme is skipped and listed in ``problems``; it never stops the store. When that file is named
/// after a built-in theme, the store neither writes over it nor removes it.
public final class ThemeStore {
    /// What changed, as observers receive it.
    nonisolated public struct Changes: OptionSet, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        /// ``ThemeStore/current`` or ``ThemeStore/selectedName`` changed. The panel restyles.
        public static let current = Changes(rawValue: 1 << 0)
        /// ``ThemeStore/themes`` or ``ThemeStore/problems`` changed. Settings redraws its list.
        public static let list = Changes(rawValue: 1 << 1)
    }

    /// The token that removes an observer.
    nonisolated public struct ObserverID: Hashable, Sendable {
        fileprivate let value: Int
    }

    /// The name of ``Theme/standard``, the theme used when nothing else is selected.
    nonisolated public static let standardName = "Standard"

    /// Every built-in theme as it ships, Standard first, with a sentence each for the settings
    /// window. ``themes`` lists them with the user's changes.
    public static let builtInThemes: [NamedTheme] = [
        NamedTheme(
            name: standardName, theme: .standard, isBuiltIn: true,
            summary: "One slab of frosted glass with a lens in the system accent color."),
        NamedTheme(
            name: "Graphite", theme: .graphite, isBuiltIn: true,
            summary: "Neutral grey glass with a flat graphite lens."),
        NamedTheme(
            name: "Ocean", theme: .ocean, isBuiltIn: true,
            summary: "Glass tinted toward blue-green with a rounder teal lens."),
        NamedTheme(
            name: "Ember", theme: .ember, isBuiltIn: true, summary: "Warm glass with a wide orange lens."),
        NamedTheme(
            name: "Violet", theme: .violet, isBuiltIn: true,
            summary: "The app icon's ink and violet, with a magenta lens."),
        NamedTheme(name: "Spotlight", theme: .spotlight, isBuiltIn: true, summary: Theme.spotlightSummary),
        NamedTheme(name: "Glass", theme: .glass, isBuiltIn: true, summary: Theme.glassSummary),
    ]

    /// Names earlier builds gave built-in themes, with the name each has now. A name an earlier
    /// build stored selects the renamed theme, and a theme file with one of these names is skipped,
    /// as it was then, so the old name always means the built-in theme. Such a file never holds
    /// changes to the built-in theme either: only a file with the theme's name now does.
    nonisolated public static let formerNames: [String: String] = ["Beam": "Spotlight", "Clear": "Glass"]

    /// The name a built-in theme has now for a name it had in an earlier build, or the name itself.
    nonisolated public static func currentName(for name: String) -> String {
        formerNames.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value ?? name
    }

    /// The built-in theme with this name as it ships, ignoring case. A former name finds it too.
    public static func builtInTheme(named name: String) -> NamedTheme? {
        let current = currentName(for: name)
        return builtInThemes.first { $0.name.caseInsensitiveCompare(current) == .orderedSame }
    }

    /// The folder of theme files: the user's themes and the changes to built-in themes. Created on
    /// the first save.
    public let folder: URL
    /// The built-in themes, with the user's changes, then the user's themes ordered by name.
    public private(set) var themes: [NamedTheme] = ThemeStore.builtInThemes
    /// Theme files that were skipped, with the reason, from the last scan.
    public private(set) var problems: [ThemeFileProblem] = []
    /// The name of the theme in use.
    public private(set) var selectedName = ThemeStore.standardName
    /// The theme in use.
    public private(set) var current = Theme.standard

    private var observers: [Int: @MainActor (Changes) -> Void] = [:]
    private var nextObserver = 0
    /// The file each built-in theme's changes came from in the last scan, by the theme's name. On a
    /// volume that tells case apart it can be spelled unlike the theme, such as `standard.json`, and
    /// it is the file an update writes and a reset removes.
    private var changesFiles: [String: URL] = [:]
    /// The file named after a built-in theme that the last scan could not read, by the theme's name.
    /// The store neither writes over it nor removes it, so what the user wrote in it by hand stays.
    private var unreadableChangesFiles: [String: ThemeFileProblem] = [:]

    /// Scans the folder and selects a theme.
    ///
    /// - Parameters:
    ///   - folder: Where theme files live. It need not exist yet.
    ///   - name: The theme to select, such as the stored setting. Standard when no theme has it.
    public init(folder: URL, selecting name: String = ThemeStore.standardName) {
        self.folder = folder
        scan()
        let named = theme(named: name) ?? standard
        selectedName = named.name
        current = named.theme
    }

    /// The theme with this name, ignoring case. A built-in theme's former name finds it too.
    public func theme(named name: String) -> NamedTheme? {
        let current = Self.currentName(for: name)
        return themes.first { $0.name.caseInsensitiveCompare(current) == .orderedSame }
    }

    /// Selects a theme by name, ignoring case. Returns false and changes nothing when no theme has
    /// it.
    @discardableResult
    public func select(_ name: String) -> Bool {
        guard let named = theme(named: name) else { return false }
        let changed = named.name != selectedName || named.theme != current
        selectedName = named.name
        current = named.theme
        if changed { notify(.current) }
        return true
    }

    /// Reads the folder again, as after files changed behind the store's back. When the selected
    /// theme's file changed it becomes current; when it is gone Standard does.
    public func reload() {
        scan()
        var changes: Changes = .list
        let named = theme(named: selectedName) ?? standard
        if named.name != selectedName || named.theme != current {
            selectedName = named.name
            current = named.theme
            changes.insert(.current)
        }
        notify(changes)
    }

    /// Sets the values of the theme with this name, ignoring case, as the settings window does
    /// while the user changes a theme.
    ///
    /// The change takes effect in memory first: the theme is listed with the new values and, when
    /// it is selected, becomes current, and observers hear of it. Then the file is written: a user
    /// theme's file, or for a built-in theme the file of its changes, which is removed instead when
    /// the theme equals the one that ships.
    ///
    /// Throws ``ThemeStoreError/unknownTheme(_:)`` when no theme has the name,
    /// ``ThemeStoreError/unreadable(_:reason:)`` when the change has to go into a file named after
    /// a built-in theme that the last scan could not read, which the store leaves as it is, and
    /// the file system's error when the file cannot be written or removed. Then the change is in
    /// place until the store reads the folder again, but it was not kept. A built-in theme set back
    /// to the values it ships with needs no file, so that never throws for a file the scan could
    /// not read.
    public func update(_ theme: Theme, for name: String) throws {
        let wanted = Self.currentName(for: name)
        guard let index = themes.firstIndex(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame })
        else { throw ThemeStoreError.unknownTheme(name) }
        var entry = themes[index]
        entry.theme = theme
        if entry.isBuiltIn { entry.isCustomized = theme != Self.builtInTheme(named: entry.name)?.theme }
        themes[index] = entry
        notify(makeCurrent(entry, changes: .list))
        guard entry.isBuiltIn else { return try write(theme, to: fileURL(for: entry.name)) }
        if entry.isCustomized {
            let file = try changesFile(of: entry.name)
            try write(theme, to: file)
            changesFiles[entry.name] = file
        } else {
            try removeChangesFile(of: entry.name)
        }
    }

    /// Puts a built-in theme back as it ships, ignoring case, and removes the file of its changes.
    /// Does nothing for a theme of the user's own. A file with the theme's name that the last scan
    /// could not read stays as it is: the store never listed its changes, so the theme is as it
    /// ships either way. Throws ``ThemeStoreError/unknownTheme(_:)`` when no theme has the name, and
    /// the file system's error when the file cannot be removed. Then the theme is back as it ships
    /// until the store reads the folder again.
    public func reset(_ name: String) throws {
        guard let named = theme(named: name) else { throw ThemeStoreError.unknownTheme(name) }
        guard named.isBuiltIn, let shipped = Self.builtInTheme(named: named.name) else { return }
        if let index = themes.firstIndex(where: { $0.name == shipped.name }), themes[index] != shipped {
            themes[index] = shipped
            notify(makeCurrent(shipped, changes: .list))
        }
        try removeChangesFile(of: shipped.name)
    }

    /// Saves a theme as a user theme, replacing one with the same name. When that theme is
    /// selected, the saved theme becomes current.
    ///
    /// Throws ``ThemeStoreError/invalidName(_:)`` for a name that cannot be a file name,
    /// ``ThemeStoreError/builtInName(_:)`` for the name of a built-in theme, and the file system's
    /// error when the file cannot be written.
    public func save(_ theme: Theme, as name: String) throws {
        let name = try validatedName(name)
        if let existing = self.theme(named: name), existing.isBuiltIn {
            throw ThemeStoreError.builtInName(existing.name)
        }
        let stored = self.theme(named: name)?.name ?? name
        try write(theme, to: fileURL(for: stored))
        let entry = NamedTheme(name: stored, theme: theme, isBuiltIn: false)
        themes.removeAll { $0.name == stored }
        themes.append(entry)
        themes = themes.filter(\.isBuiltIn) + userThemesSorted()
        var changes: Changes = .list
        if stored == selectedName && theme != current {
            current = theme
            changes.insert(.current)
        }
        notify(changes)
    }

    /// Deletes a user theme's file. When it was selected, Standard, with the user's changes,
    /// becomes current. Throws ``ThemeStoreError/builtInName(_:)`` for a built-in theme and
    /// ``ThemeStoreError/unknownTheme(_:)`` when no theme has the name.
    public func delete(_ name: String) throws {
        guard let named = theme(named: name) else { throw ThemeStoreError.unknownTheme(name) }
        if named.isBuiltIn { throw ThemeStoreError.builtInName(named.name) }
        try FileManager.default.removeItem(at: fileURL(for: named.name))
        themes.removeAll { $0.name == named.name }
        var changes: Changes = .list
        if named.name == selectedName {
            let standard = self.standard
            selectedName = standard.name
            current = standard.theme
            changes.insert(.current)
        }
        notify(changes)
    }

    /// Copies a theme file into the folder as a user theme and returns its name: the file name,
    /// with " 2", " 3" and so on added when a theme already has it. Throws
    /// ``ThemeStoreError/unreadable(_:reason:)`` when the file is not a theme.
    @discardableResult
    public func importTheme(from url: URL) throws -> String {
        let theme = try Self.decode(url)
        let base = (try? validatedName(url.deletingPathExtension().lastPathComponent)) ?? "Imported Theme"
        var name = base
        var number = 2
        while self.theme(named: name) != nil {
            name = base + " " + String(number)
            number += 1
        }
        try save(theme, as: name)
        return name
    }

    /// Writes a theme, built-in or user, to a file the user chose. Throws
    /// ``ThemeStoreError/unknownTheme(_:)`` when no theme has the name.
    public func exportTheme(named name: String, to url: URL) throws {
        guard let named = theme(named: name) else { throw ThemeStoreError.unknownTheme(name) }
        try Self.encode(named.theme).write(to: url, options: .atomic)
    }

    /// Calls `handler` after each change, on the main actor, until ``removeObserver(_:)``.
    @discardableResult
    public func addObserver(_ handler: @escaping @MainActor (Changes) -> Void) -> ObserverID {
        nextObserver += 1
        observers[nextObserver] = handler
        return ObserverID(value: nextObserver)
    }

    /// Stops calling an observer.
    public func removeObserver(_ id: ObserverID) {
        observers[id.value] = nil
    }

    // MARK: Files

    private func notify(_ changes: Changes) {
        for key in observers.keys.sorted() {
            observers[key]?(changes)
        }
    }

    /// Standard as the store lists it, with the user's changes.
    private var standard: NamedTheme {
        themes.first { $0.name == Self.standardName } ?? Self.builtInThemes[0]
    }

    /// Makes a theme that was just listed with new values current when it is the selected one, and
    /// returns `changes` with ``Changes/current`` added when current changed.
    private func makeCurrent(_ entry: NamedTheme, changes: Changes) -> Changes {
        guard entry.name == selectedName, entry.theme != current else { return changes }
        current = entry.theme
        return changes.union(.current)
    }

    private func scan() {
        var builtIns = Self.builtInThemes
        var changed: Set<String> = []
        var found: [NamedTheme] = []
        var skipped: [ThemeFileProblem] = []
        changesFiles = [:]
        unreadableChangesFiles = [:]
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let themeFiles = files.filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for file in themeFiles {
            let name = file.deletingPathExtension().lastPathComponent
            let builtIn = builtIns.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            let taken = Array(Self.formerNames.keys) + found.map(\.name) + Array(changed)
            if taken.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                skipped.append(ThemeFileProblem(file: file, reason: "another theme already has the name \(name)"))
                continue
            }
            let theme: Theme
            do {
                theme = try Self.decode(file)
            } catch {
                let problem = ThemeFileProblem(
                    file: file, reason: (error as? ThemeStoreError)?.reason ?? error.localizedDescription)
                skipped.append(problem)
                if let builtIn, unreadableChangesFiles[builtIns[builtIn].name] == nil {
                    unreadableChangesFiles[builtIns[builtIn].name] = problem
                }
                continue
            }
            if let builtIn {
                // The user's changes to a built-in theme.
                changed.insert(builtIns[builtIn].name)
                changesFiles[builtIns[builtIn].name] = file
                builtIns[builtIn].isCustomized = theme != builtIns[builtIn].theme
                builtIns[builtIn].theme = theme
            } else {
                found.append(NamedTheme(name: name, theme: theme, isBuiltIn: false))
            }
        }
        themes = builtIns + found
        problems = skipped
    }

    /// The file to write a built-in theme's changes to: the one the last scan read, whatever its
    /// case, or a new one named after the theme. Throws when the last scan could not read the file
    /// with the theme's name, so an update never replaces what the user wrote there.
    private func changesFile(of name: String) throws -> URL {
        if let file = changesFiles[name] { return file }
        if let problem = unreadableChangesFiles[name] {
            throw ThemeStoreError.unreadable(problem.file, reason: problem.reason)
        }
        return fileURL(for: name)
    }

    /// Removes the file of a built-in theme's changes. A file with the theme's name that the last
    /// scan could not read is not the store's to remove. It stays as the user left it, and the
    /// theme is as it ships either way.
    private func removeChangesFile(of name: String) throws {
        if let file = changesFiles[name] {
            try removeFile(file)
            changesFiles[name] = nil
        } else if unreadableChangesFiles[name] == nil {
            try removeFile(fileURL(for: name))
        }
    }

    private func write(_ theme: Theme, to file: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.encode(theme).write(to: file, options: .atomic)
    }

    private func removeFile(_ file: URL) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }

    private func userThemesSorted() -> [NamedTheme] {
        themes.filter { !$0.isBuiltIn }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func fileURL(for name: String) -> URL {
        folder.appending(path: name + ".json", directoryHint: .notDirectory)
    }

    private func validatedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 100, !trimmed.hasPrefix("."),
            !trimmed.contains(where: { $0 == "/" || $0 == ":" || $0.isNewline })
        else { throw ThemeStoreError.invalidName(name) }
        return trimmed
    }

    private static func encode(_ theme: Theme) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(theme)
    }

    private static func decode(_ url: URL) throws -> Theme {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ThemeStoreError.unreadable(url, reason: "the file cannot be read")
        }
        do {
            return try JSONDecoder().decode(Theme.self, from: data)
        } catch let error as DecodingError {
            throw ThemeStoreError.unreadable(url, reason: describe(error))
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ keys: [any CodingKey]) -> String {
            guard !keys.isEmpty else { return "the top level" }
            return keys.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "missing \(path(context.codingPath + [key]))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "wrong value at \(path(context.codingPath))"
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty ? "not JSON" : "bad value at \(path(context.codingPath))"
        @unknown default:
            return "not a theme"
        }
    }
}

/// A theme with the name the store lists it under.
nonisolated public struct NamedTheme: Identifiable, Sendable, Equatable {
    /// Unique among the store's themes, ignoring case. A theme file's name without `.json`.
    public var name: String
    public var theme: Theme
    /// True for a theme that ships with the app. Built-in themes cannot be saved over under their
    /// name or deleted. The user's changes to one are kept apart and can be reset.
    public var isBuiltIn: Bool
    /// True for a built-in theme that differs from the one that ships, because the user changed it.
    public var isCustomized: Bool
    /// One or two sentences on what the theme looks like as it ships, for the settings window.
    /// Empty for a user theme.
    public var summary: String

    public var id: String { name }

    public init(name: String, theme: Theme, isBuiltIn: Bool, isCustomized: Bool = false, summary: String = "") {
        self.name = name
        self.theme = theme
        self.isBuiltIn = isBuiltIn
        self.isCustomized = isCustomized
        self.summary = summary
    }
}

/// A theme file the store skipped.
nonisolated public struct ThemeFileProblem: Sendable, Equatable {
    public var file: URL
    /// Why, such as "missing light.title".
    public var reason: String
}

/// Why the store refused a request.
nonisolated public enum ThemeStoreError: Error, Equatable, LocalizedError {
    /// The name is empty, too long, starts with "." or holds "/", ":" or a line break.
    case invalidName(String)
    /// A built-in theme has the name.
    case builtInName(String)
    /// No theme has the name.
    case unknownTheme(String)
    /// The file cannot be read or is not a theme.
    case unreadable(URL, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name): "\"\(name)\" cannot be a theme name."
        case .builtInName(let name): "\(name) is a built-in theme. Save it under another name."
        case .unknownTheme(let name): "There is no theme named \(name)."
        case .unreadable(let url, let reason): "\(url.lastPathComponent) is not a theme: \(reason)."
        }
    }

    fileprivate var reason: String {
        if case .unreadable(_, let reason) = self { return reason }
        return errorDescription ?? "not a theme"
    }
}

// MARK: - Built-in themes

extension Theme {
    /// Neutral grey glass in dark mode, a flat fill lens and a graphite accent. In light mode the
    /// lens is a mid graphite fill, dense enough to show over a white or busy backdrop.
    public static let graphite = Theme.standard.variant(
        darkTint: rgb(0x1C1D20, alpha: 0.55), accent: rgb(0x5A5F66),
        lens: LensMetrics(style: .fill, horizontalInset: 8, cornerRadius: 10), tintsFillLens: false,
        lightLensFill: rgb(0x787D85, alpha: 0.28))

    /// Glass tinted toward blue-green in dark mode, a rounder glass lens and a deep teal accent. In
    /// light mode the lens is tinted sea green, away from the system blue that Standard uses.
    public static let ocean = Theme.standard.variant(
        darkTint: rgb(0x06202B, alpha: 0.55), accent: rgb(0x0B6E8A),
        lens: LensMetrics(style: .glass, horizontalInset: 6, cornerRadius: 16), tintsFillLens: false,
        lightLensTint: rgb(0x00A6A0, alpha: 0.30))

    /// Warm glass in dark mode, a wide fill lens in the accent and a deep orange accent. In light
    /// mode the lens is a brighter orange, which reads as warm where the accent's own tint read as
    /// grey.
    public static let ember = Theme.standard.variant(
        darkTint: rgb(0x2A140A, alpha: 0.55), accent: rgb(0xB5470F),
        lens: LensMetrics(style: .fill, horizontalInset: 10, cornerRadius: 14), tintsFillLens: true,
        lightLensFill: rgb(0xF07A2A, alpha: 0.30))

    /// The app icon's palette: ink glass in dark mode, an electric violet accent and a glass lens
    /// tinted magenta.
    public static let violet = Theme.standard.variant(
        darkTint: rgb(0x24064C, alpha: 0.55), accent: rgb(0x8743FA),
        lens: LensMetrics(style: .glass, horizontalInset: 7, cornerRadius: 12), tintsFillLens: false,
        lensTint: rgb(0xA522FC))

    /// A copy with another dark glass tint, lens and accent. Every colour Standard takes from the
    /// system accent takes `accent` instead, at the same alpha. Accents are dark enough for white
    /// text on a prominent button at 4.5:1. A `lensTint` replaces the accent in the glass lens only.
    ///
    /// Light mode keeps Standard's white tint. The glass treats any other colour as a coloured
    /// tint, and over a dark backdrop that cost titles 0.4 to 1.3 of contrast, under 4.5:1,
    /// even for a tint as pale as #FAFAFB. Pure white or black tints keep the measured contrast.
    /// So a theme shows its colour in light mode through the lens: `lightLensFill` and
    /// `lightLensTint` replace the light lens's fill and glass tint. A mid-tone fill darkens the
    /// lens over a white backdrop and barely over a dark one, where the light glass is darkest and
    /// titles have the least contrast to spare.
    private func variant(
        darkTint: ThemeColor, accent: ThemeColor, lens: LensMetrics, tintsFillLens: Bool, lensTint: ThemeColor? = nil,
        lightLensFill: ThemeColor? = nil, lightLensTint: ThemeColor? = nil
    ) -> Theme {
        var theme = self
        theme.light = light.accented(accent, tint: light.glassTint, fillLensAlpha: tintsFillLens ? 0.16 : nil)
        theme.dark = dark.accented(accent, tint: darkTint, fillLensAlpha: tintsFillLens ? 0.24 : nil)
        if let lensTint {
            theme.light.lensGlassTint = lensTint.scaled(by: light.lensGlassTint.alpha)
            theme.dark.lensGlassTint = lensTint.scaled(by: dark.lensGlassTint.alpha)
        }
        if let lightLensFill { theme.light.lensFill = lightLensFill }
        if let lightLensTint { theme.light.lensGlassTint = lightLensTint }
        theme.lens = lens
        return theme
    }

    /// An opaque sRGB colour from a hex value, so it survives the 8-bit hex form of theme files.
    private static func rgb(_ hex: UInt32, alpha: Double = 1) -> ThemeColor {
        ThemeColor(
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension ThemePalette {
    fileprivate func accented(_ accent: ThemeColor, tint: ThemeColor, fillLensAlpha: Double?) -> ThemePalette {
        func swap(_ color: ThemeColor) -> ThemeColor {
            color.source == .system(.accent) ? accent.scaled(by: color.alpha) : color
        }
        var palette = self
        palette.glassTint = tint
        palette.fieldTint = tint
        palette.caret = swap(caret)
        palette.lensGlassTint = swap(lensGlassTint)
        palette.link = swap(link)
        palette.focusRing = swap(focusRing)
        palette.prominent = swap(prominent)
        palette.loadingBar = swap(loadingBar)
        if let fillLensAlpha { palette.lensFill = accent.scaled(by: fillLensAlpha) }
        return palette
    }
}
