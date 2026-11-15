import Foundation
import Kit
import KitTesting
import Testing

@testable import Windows

@MainActor
@Suite("Switch Windows", .timeLimit(.minutes(1)))
struct SwitchWindowsTests {
    static func window(
        _ process: Int32, _ token: Int, _ title: String, _ app: String, minimized: Bool = false, hidden: Bool = false
    ) -> SimulatedWindows.Window {
        SimulatedWindows.Window(
            ref: WindowRef(process: process, token: token), title: title, appName: app,
            bundleID: "com.example." + app.lowercased().replacingOccurrences(of: " ", with: "-"),
            frame: Frame(x: 100, y: 100, width: 600, height: 400), isMinimized: minimized, isAppHidden: hidden)
    }

    /// Front to back: two editor windows around a browser window, a hidden app's window, a
    /// minimized one, and a window with no title.
    static let desk: [SimulatedWindows.Window] = [
        window(10, 1, "Draft", "Example Editor"),
        window(20, 1, "Start Page", "Example Browser"),
        window(10, 2, "Notes", "Example Editor"),
        window(30, 1, "Inbox", "Example Mail", hidden: true),
        window(40, 1, "Old Report", "Example Viewer", minimized: true),
        window(50, 1, "  ", "Example Player"),
    ]

    func opened() async throws -> WindowsHarness {
        let windows = WindowsHarness(windows: Self.desk)
        try await windows.harness.run(WindowCommands.switchWindowsID)
        return windows
    }

    @Test func listsWindowsMostRecentFirstWithMinimizedLast() async throws {
        let windows = try await opened()
        let harness = windows.harness
        #expect(harness.issues.isEmpty)
        #expect(harness.rows.map(\.title) == ["Draft", "Start Page", "Notes", "Inbox", "Example Player", "Old Report"])
        #expect(
            harness.rows.map(\.subtitle) == [
                "Example Editor", "Example Browser", "Example Editor", "Example Mail", "Example Player",
                "Example Viewer",
            ])
        #expect(harness.selectedRow?.title == "Draft")
        #expect(harness.rows[0].accessories == [.tag(Strings.currentTag)])
        #expect(harness.rows[3].accessories == [.tag(Strings.hiddenTag)])
        #expect(harness.rows[5].accessories == [.tag(Strings.minimizedTag)])
        #expect(harness.rows.allSatisfy { $0.memory == .never })
        #expect(harness.rows[0].icon == .app(bundleID: "com.example.example-editor"))
        #expect(harness.sections.first?.showsCount == true)
    }

    @Test func searchesByTitleAndByApp() async throws {
        let windows = try await opened()
        try await windows.harness.setQuery("notes")
        #expect(windows.harness.rows.map(\.title) == ["Notes"])
        try await windows.harness.setQuery("example editor")
        #expect(windows.harness.rows.map(\.title) == ["Draft", "Notes"], "most recent first among equals")
    }

    @Test func returnSwitchesToTheWindowAndCloses() async throws {
        let windows = try await opened()
        try windows.harness.select(title: "Old Report")
        #expect(windows.harness.actions().map(\.id) == ["focus", "close"], "a minimized window has no Minimize")
        try await windows.harness.performPrimary()
        #expect(windows.harness.isClosed)
        #expect(windows.desktop.windows.first?.title == "Old Report")
        #expect(windows.desktop.focused?.isMinimized == false)
    }

    @Test func minimizeKeepsThePanelOpenAndRelists() async throws {
        let windows = try await opened()
        try windows.harness.select(title: "Notes")
        let minimize = try #require(windows.harness.actions().first { $0.id == "minimize" })
        #expect(minimize.shortcut == KeyCombo(.m, .command))
        try await windows.harness.perform("minimize")
        #expect(!windows.harness.isClosed)
        #expect(windows.harness.visibleToast?.title == Strings.minimizedToast)
        // Minimized windows follow the others, in their own most recent order.
        #expect(windows.harness.rows.suffix(2).map(\.title) == ["Notes", "Old Report"])
        #expect(windows.harness.rows.first { $0.title == "Notes" }?.accessories == [.tag(Strings.minimizedTag)])
    }

    @Test func closeAsksFirstAndHonorsNo() async throws {
        let windows = try await opened()
        try windows.harness.select(title: "Start Page")
        let close = try #require(windows.harness.actions().first { $0.id == "close" })
        #expect(close.style == .destructive)
        #expect(close.shortcut == .remove)
        #expect(close.confirmation?.suppressionKey == "close-window")

        windows.harness.confirmationAnswer = false
        try await windows.harness.perform("close")
        #expect(windows.desktop.windows.count == Self.desk.count)

        windows.harness.confirmationAnswer = true
        try await windows.harness.perform("close")
        #expect(windows.harness.confirmations.count == 2)
        #expect(!windows.desktop.windows.contains { $0.title == "Start Page" })
        #expect(!windows.harness.rows.contains { $0.title == "Start Page" })
        #expect(windows.harness.visibleToast?.title == Strings.closedToast)
    }

    @Test func aWindowThatClosedMeanwhileRelistsWithAMessage() async throws {
        let windows = try await opened()
        try windows.harness.select(title: "Notes")
        windows.desktop.windows.removeAll { $0.title == "Notes" }
        try await windows.harness.performPrimary()
        #expect(!windows.harness.isClosed)
        #expect(windows.harness.visibleToast?.title == Strings.windowGone)
        #expect(!windows.harness.rows.contains { $0.title == "Notes" })
    }

    @Test func accessibilityLostWhileOpenShowsANoticeWithAGrantButton() async throws {
        let windows = try await opened()
        windows.desktop.accessibilityGranted = false
        try await windows.harness.reloadPage()
        #expect(windows.harness.rows.isEmpty)
        let notice = try #require(windows.harness.page?.notice)
        #expect(notice.title == Strings.needsAccessTitle)
        #expect(notice.action?.requires == [.accessibility])
        // An action on a row that went stale asks the host to run its grant flow.
        await #expect(throws: HarnessError.permissionRequired([.accessibility])) {
            let row = Row(id: ItemID(WindowList.namespace, WindowRef(process: 10, token: 1).key), title: "Draft")
            let focus = try #require(windows.harness.feature.windowList.actions(for: row).first)
            try await windows.harness.perform(focus, row: row)
        }
    }

    @Test func actionsWorkFromTheRowIDAlone() throws {
        let windows = WindowsHarness(windows: Self.desk)
        let row = Row(id: ItemID(WindowList.namespace, WindowRef(process: 10, token: 2).key), title: "Notes")
        let actions = windows.harness.feature.windowList.actions(for: row)
        #expect(actions.map(\.id) == ["focus", "minimize", "close"])
        let foreign = Row(id: ItemID(WindowList.namespace, "not-a-window"), title: "Nothing")
        #expect(windows.harness.feature.windowList.actions(for: foreign).isEmpty)
    }

    @Test func anEmptyDesktopShowsTheEmptyState() async throws {
        let windows = WindowsHarness(windows: [])
        try await windows.harness.run(WindowCommands.switchWindowsID)
        #expect(windows.harness.rows.isEmpty)
        #expect(windows.harness.page?.emptyState?.title == Strings.noWindowsTitle)
    }

    @Test func rowsCarryTheirWindowAndStaySmall() throws {
        let rows = WindowList.rows([
            OpenWindow(
                ref: WindowRef(process: 1, token: 2), title: String(repeating: "x", count: 200), appName: "Example",
                bundleID: "com.example.app")
        ])
        let payload = try #require(rows.first?.payload)
        #expect(try payload.decode(OpenWindow.self).ref == WindowRef(process: 1, token: 2))
        let encoded = try JSONEncoder().encode(rows[0])
        #expect(encoded.count < 1024)
    }
}
