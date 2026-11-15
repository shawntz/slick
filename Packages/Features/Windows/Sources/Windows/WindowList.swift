import Foundation
import Kit

/// The Switch Windows page: every open window across apps, most recently used first.
///
/// The host filters by title and by app name. Rows carry their window as the payload, so their
/// actions need nothing else. Window references do not outlive the window, so root search keeps no
/// snapshot of these rows.
final class WindowList: ListSource {
    nonisolated static let namespace = "windows"

    private let windows: any WindowService
    /// Sent after the page changed a window, so the host lists them again.
    let changes: ChangeSignal? = ChangeSignal()

    init(windows: any WindowService) {
        self.windows = windows
    }

    func load(_ request: ListRequest) async throws -> ListResult {
        do {
            let open = try await windows.openWindows()
            try Task.checkCancellation()
            let rows = await Self.buildRows(open)
            return ListResult(sections: [
                ListSection(Strings.windowsSection, id: "windows", showsCount: true, rows: rows)
            ])
        } catch WindowError.accessibilityMissing {
            return ListResult(sections: [], notice: accessNotice)
        }
    }

    func actions(for row: Row) -> [Action] {
        let window = try? row.payload?.decode(OpenWindow.self)
        guard let ref = window?.ref ?? WindowRef(key: row.id.key) else { return [] }
        let windows = windows
        var actions = [
            Action(
                Strings.switchToWindow, id: "focus", icon: .symbol("macwindow"), requires: [.accessibility]
            ) { context in
                try await self.handling(context) {
                    try await windows.focus(ref)
                    return .close()
                }
            }
        ]
        if window?.isMinimized != true {
            actions.append(
                Action(
                    Strings.minimizeWindow, id: "minimize", icon: .symbol("minus.rectangle"),
                    shortcut: KeyCombo(.m, .command), requires: [.accessibility]
                ) { context in
                    try await self.handling(context) {
                        try await windows.minimize(ref)
                        self.changes?.send()
                        context.showToast(.success(Strings.minimizedToast))
                        return .keepOpen
                    }
                })
        }
        actions.append(
            Action(
                Strings.closeWindow, id: "close", icon: .symbol("xmark.rectangle"), shortcut: .remove,
                style: .destructive,
                confirmation: Confirmation(
                    Strings.closeQuestion(title: window.map { Self.title($0, limit: 80) }, app: window?.appName),
                    message: Strings.closeMessage(app: window?.appName), confirmTitle: Strings.closeWindow,
                    isDestructive: true, suppressionKey: "close-window"),
                requires: [.accessibility]
            ) { context in
                try await self.handling(context) {
                    try await windows.close(ref)
                    self.changes?.send()
                    context.showToast(.success(Strings.closedToast))
                    return .keepOpen
                }
            })
        return actions
    }

    /// The rows, built off the main thread, since a desk can hold hundreds of windows.
    @concurrent nonisolated static func buildRows(_ windows: [OpenWindow]) async -> [Row] {
        rows(windows)
    }

    /// One row per window, in the order given. Plain values, so any thread can build them.
    nonisolated static func rows(_ windows: [OpenWindow]) -> [Row] {
        windows.enumerated().map { index, window in
            var tags: [Accessory] = []
            if window.isFocused { tags.append(.tag(Strings.currentTag)) }
            if window.isMinimized { tags.append(.tag(Strings.minimizedTag)) }
            if window.isAppHidden { tags.append(.tag(Strings.hiddenTag)) }
            let title = Self.title(window)
            return Row(
                id: ItemID(namespace, window.ref.key), title: title.isEmpty ? window.appName : title,
                subtitle: window.appName, icon: window.bundleID.map { .app(bundleID: $0) } ?? .symbol("macwindow"),
                accessories: tags, keywords: [window.appName], payload: Payload(window),
                rankHint: Double(windows.count - index), memory: .never)
        }
    }

    /// The window's title on one line: control characters and line breaks become spaces, and
    /// spaces at either end go. Empty for a window without a title. With a limit, only that many
    /// characters are read, which keeps `actions(for:)` quick on the main thread for a title of
    /// thousands of characters.
    nonisolated static func title(_ window: OpenWindow, limit: Int? = nil) -> String {
        let source = limit.map { Substring(window.title.prefix($0)) } ?? Substring(window.title)
        let line = String(
            String.UnicodeScalarView(
                source.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs an action's work and turns the service's errors into what the host shows: the grant
    /// card when Accessibility went away, and a fresh list when the window closed meanwhile.
    private func handling(_ context: ActionContext, _ work: () async throws -> ActionOutcome) async throws
        -> ActionOutcome
    {
        do {
            return try await work()
        } catch WindowError.accessibilityMissing {
            return .needsPermission(.accessibility)
        } catch WindowError.windowGone {
            changes?.send()
            context.showToast(.failure(Strings.windowGone))
            return .keepOpen
        }
    }

    private var accessNotice: Notice {
        Notice(
            icon: .symbol("lock"), title: Strings.needsAccessTitle, message: Strings.needsAccessMessage,
            action: Action(Strings.grantAccess, id: "grant-access", requires: [.accessibility]) { context in
                context.reload()
                return .keepOpen
            })
    }
}
