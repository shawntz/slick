import Foundation
import Kit

/// The actions of a bookmark row, made from the row alone: the loaded bookmark when the row's key
/// is in the snapshot, else the row's payload, as for a row root search kept from before a relaunch.
///
/// Only web links open without a question. See ``LinkKind`` for what each kind of link gets.
final class BookmarkActions {
    private let library: BookmarkLibrary
    private let context: FeatureContext

    init(library: BookmarkLibrary, context: FeatureContext) {
        self.library = library
        self.context = context
    }

    /// What the actions need to know about one bookmark.
    struct Target {
        var title: String
        var link: String
        var kind: LinkKind
        var browser: Browser
    }

    /// The bookmark a row stands for, or nil when neither the snapshot nor the payload has its link.
    func target(for row: Row) -> Target? {
        if row.id.namespace == BookmarkIndex.namespace, let bookmark = library.snapshot.bookmark(key: row.id.key) {
            return Target(title: bookmark.title, link: bookmark.link, kind: bookmark.kind, browser: bookmark.browser)
        }
        guard let payload = try? row.payload?.decode(BookmarkPayload.self), let link = payload.link else { return nil }
        // The kind is worked out again rather than trusted from a stored payload.
        return Target(title: payload.title, link: link, kind: LinkKind.of(link), browser: payload.browser)
    }

    func actions(for row: Row) -> [Action] {
        guard let target = target(for: row) else { return [] }
        return actions(for: target)
    }

    func actions(for target: Target) -> [Action] {
        let copies = copyActions(for: target)
        guard let url = LinkKind.url(target.link) else { return copies }
        switch target.kind {
        case .web:
            return openActions(url, browser: target.browser) + [.openWith(url)] + copies
        case .file:
            guard url.isFileURL else { return copies }
            return [.reveal([url]), openFile(url)] + copies
        case .app:
            return [openInApp(url, scheme: LinkKind.scheme(of: target.link) ?? "")] + copies
        case .script, .browserPage, .invalid:
            return copies
        }
    }

    /// Open in the default browser and in the browser the bookmark came from, in the order the
    /// setting asks for. The second is left out when that browser is not installed.
    private func openActions(_ url: URL, browser: Browser) -> [Action] {
        let inDefault = Action(
            Strings.Actions.openInDefaultBrowser, id: "open-default", icon: .symbol("globe")
        ) { context in
            try await context.workspace.open(url)
            return .close()
        }
        guard let app = context.workspace.application(bundleID: browser.bundleID) else { return [inDefault] }
        let inSource = Action(
            Strings.Actions.openIn(app.name), id: "open-source", icon: .app(bundleID: browser.bundleID)
        ) { context in
            try await context.workspace.open([url], withApplication: browser.bundleID)
            return .close()
        }
        switch context.settings[BookmarkSettings.opensIn] {
        case .defaultBrowser: return [inDefault, inSource]
        case .sourceBrowser: return [inSource, inDefault]
        }
    }

    /// Opens a link that starts another app, after saying so.
    private func openInApp(_ url: URL, scheme: String) -> Action {
        Action(
            Strings.Actions.openLink, id: "open-link", icon: .symbol("arrow.up.forward.app"),
            confirmation: Confirmation(
                Strings.Actions.openLinkQuestion, message: Strings.Actions.openLinkMessage(scheme: scheme),
                confirmTitle: Strings.Actions.openLink)
        ) { context in
            try await context.workspace.open(url)
            return .close()
        }
    }

    /// Opens a file on this Mac, after saying that it may be an app or a script.
    private func openFile(_ url: URL) -> Action {
        Action(
            Strings.Actions.openFile, id: "open-file", icon: .symbol("doc"),
            confirmation: Confirmation(
                Strings.Actions.openFileQuestion(name: url.lastPathComponent), message: Strings.Actions.openFileMessage,
                confirmTitle: Strings.Actions.openFile)
        ) { context in
            try await context.workspace.open(url)
            return .close()
        }
    }

    private func copyActions(for target: Target) -> [Action] {
        var actions: [Action] = [
            .copy(target.link, title: Strings.Actions.copyLink, hud: Strings.Actions.copiedLink, shortcut: .copy)
                .with(id: "copy-link")
        ]
        if target.kind.opens {
            actions.append(
                .copy(
                    LinkText.markdown(title: target.title, link: target.link), title: Strings.Actions.copyMarkdown,
                    hud: Strings.Actions.copiedMarkdown, shortcut: KeyCombo(.c, [.option, .shift, .command])
                )
                .with(id: "copy-markdown"))
        }
        actions.append(
            .copy(target.title, title: Strings.Actions.copyTitle, hud: Strings.Actions.copiedTitle).with(
                id: "copy-title"))
        return actions
    }
}
