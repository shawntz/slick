import Foundation
import Kit

/// Searches the bookmarks of Safari, Chrome, Brave, Edge, Vivaldi, Opera, Chromium and Firefox.
///
/// - Every browser is off at first. Nothing is read until the user chooses a browser, in settings
///   or from the notice on Search Bookmarks. Safari needs Full Disk Access, and is never read
///   without it.
/// - The parsers in `Parsing/` are pure functions over a file's bytes. ``BookmarkFileService``
///   reads the bytes: the browsers' files in the app, synthetic ones everywhere else.
/// - ``BookmarkLibrary`` loads off the main thread, and loads again when Kit's file watcher says a
///   bookmarks file changed.
/// - Search Bookmarks lists every bookmark with its folder path; root search shows them too when
///   the user turns that on. Rows carry the browser's app icon, never a site's icon.
public final class BookmarksFeature: Feature {
    public static let manifest = FeatureManifest(
        id: "bookmarks", name: Strings.featureName, icon: .symbol("bookmark"), summary: Strings.summary,
        permissions: [PermissionNeed(.fullDiskAccess, reason: Strings.fullDiskAccessReason)])

    let context: FeatureContext
    let library: BookmarkLibrary
    private let declarations = ChangeSignal()
    private let builder: BookmarkActions
    let list: BookmarkList
    private let catalog: BookmarkCatalog

    /// Does no I/O. The live file service touches nothing until a browser is chosen and read.
    public init(context: FeatureContext) {
        self.context = context
        library = BookmarkLibrary(context: context, files: context.service(BookmarkFileServiceKey.self))
        builder = BookmarkActions(library: library, context: context)
        catalog = BookmarkCatalog(library: library, builder: builder, settings: context.settings)
        list = BookmarkList(library: library, builder: builder, context: context)
        list.chooseBrowsers = { [unowned self] in self.chooseAction }
        library.onStatusChange = { [weak self] in self?.declarations.send() }
    }

    /// Follows the settings that choose browsers. Reads no bookmarks.
    public func activate() async {
        library.start()
    }

    public func deactivate() async {
        library.stop()
    }

    public var declarationChanges: ChangeSignal? { declarations }

    public var catalogSources: [any CatalogSource] { [catalog] }

    public var status: FeatureStatus? {
        if library.safariNeedsAccess {
            return FeatureStatus(
                .warning, Strings.Notices.safariAccessTitle, message: Strings.Notices.safariAccessMessage,
                requires: [.fullDiskAccess])
        }
        if !library.problems.isEmpty {
            return FeatureStatus(
                .warning, Strings.Notices.problemsTitle, message: Strings.Notices.problemsMessage(library.problems))
        }
        return nil
    }

    // MARK: - Commands

    public var commands: [Command] {
        [
            Command(
                id: "search", title: Strings.Commands.search, icon: Self.manifest.icon,
                keywords: Strings.Commands.searchKeywords,
                arguments: [CommandArgument("query", placeholder: Strings.Commands.queryPlaceholder, isOptional: true)],
                fallback: Fallback(title: Strings.Commands.fallback)
            ) { [list] context in
                .push(.list(list.page(initialQuery: context.arguments["query"] ?? "")))
            },
            Command(
                id: "choose-browsers", title: Strings.Commands.chooseBrowsers, icon: .symbol("checklist"),
                keywords: Strings.Commands.chooseKeywords
            ) { _ in
                .push(.form(self.chooseForm()))
            },
        ]
    }

    /// Pushes the form that chooses browsers. The notice and the empty state offer it.
    var chooseAction: Action {
        .push(Strings.Commands.chooseBrowsersButton, id: "choose-browsers", icon: .symbol("checklist")) {
            .form(self.chooseForm())
        }
    }

    // MARK: - Choosing browsers

    /// The browsers the form offers: those installed, and any already chosen. Every supported one
    /// when none is installed, so the form is never empty.
    var offeredBrowsers: [Browser] {
        let chosen = Set(library.chosenBrowsers)
        let offered = Browser.allCases.filter { browser in
            chosen.contains(browser) || context.workspace.application(bundleID: browser.bundleID) != nil
        }
        return offered.isEmpty ? Browser.allCases : offered
    }

    func chooseForm() -> FormPage {
        let browsers = offeredBrowsers
        let settings = context.settings
        var fields: [FormField] = [.description(Strings.Choose.intro)]
        for browser in browsers {
            fields.append(
                FormField(
                    id: browser.rawValue, title: browser.name,
                    kind: .checkbox(
                        label: Strings.Choose.label(browser), initial: settings[BookmarkSettings.includes(browser)]),
                    info: browser.needsFullDiskAccess ? Strings.Choose.safariInfo : nil))
        }
        fields.append(.separator())
        fields.append(
            .checkbox(
                "root-search", title: Strings.Choose.rootSearchTitle, label: Strings.Choose.rootSearchLabel,
                initial: settings[BookmarkSettings.showsInRootSearch]))
        return FormPage(title: Strings.Choose.title, fields: fields, submitTitle: Strings.Choose.submit) {
            values, context in
            for browser in browsers {
                context.settings[BookmarkSettings.includes(browser)] = values.bool(browser.rawValue)
            }
            context.settings[BookmarkSettings.showsInRootSearch] = values.bool("root-search")
            return .pop
        }
    }

    // MARK: - Settings

    public var settingsPane: SettingsPane? {
        var browserItems: [SettingsItem] = []
        for browser in Browser.allCases {
            let installed = context.workspace.application(bundleID: browser.bundleID) != nil
            browserItems.append(
                .toggle(
                    browser.name, key: BookmarkSettings.includes(browser),
                    info: Strings.Settings.browserInfo(browser, installed: installed)))
            if browser == .safari {
                browserItems.append(.permission(.fullDiskAccess, info: Strings.Settings.accessInfo))
                browserItems.append(
                    .toggle(
                        Strings.Settings.readingList, key: BookmarkSettings.includesReadingList,
                        info: Strings.Settings.readingListInfo))
            }
        }
        return SettingsPane([
            SettingsSection(
                Strings.Settings.browsersSection, footer: Strings.Settings.browsersFooter, items: browserItems),
            SettingsSection(
                Strings.Settings.resultsSection,
                items: [
                    .toggle(
                        Strings.Settings.rootSearch, key: BookmarkSettings.showsInRootSearch,
                        info: Strings.Settings.rootSearchInfo(limit: BookmarkIndex.catalogLimit)),
                    .picker(
                        Strings.Settings.opensIn, key: BookmarkSettings.opensIn, info: Strings.Settings.opensInInfo,
                        titles: Strings.Settings.openTarget),
                ]),
            SettingsSection(
                Strings.Settings.privacySection,
                items: [
                    .note(Strings.Settings.readsNote),
                    .note(Strings.Settings.storesNote(cache: cacheFolderForDisplay)),
                    .note(Strings.Settings.sendsNote),
                ]),
        ])
    }

    /// The cache folder as the user reads it, with the home folder written as "~".
    var cacheFolderForDisplay: String {
        let folder = context.storage.cacheDirectory.path(percentEncoded: false)
        let home = context.storage.homeDirectory.path(percentEncoded: false)
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !trimmedHome.isEmpty, folder.hasPrefix(trimmedHome + "/") else { return folder }
        return "~" + folder.dropFirst(trimmedHome.count)
    }
}
