import Foundation
import Synchronization

/// Menu bars held in memory. Scenarios, self-tests and benchmarks use it, so they never read or
/// press anything in a real app, and tests build trees with it and read what the feature pressed.
///
/// It walks with the same ``MenuWalker`` as the live reader. Each element read can cost simulated
/// time, an app can quit or Accessibility can go away after a number of reads, and the launcher
/// can close after a number of reads, so every way a live walk ends can be played exactly.
nonisolated final class SimulatedMenus: MenuReader {
    /// One element of a menu tree: an item, a menu that opens a submenu, or a separator.
    struct Node: Hashable, Sendable {
        var title: String
        var isEnabled = true
        var shortcut = ShortcutAttributes()
        var mark = ""
        var children: [Node] = []

        /// An item. The character and modifier mask are those Accessibility reports: a mask of 0
        /// means Command alone.
        static func item(
            _ title: String, _ character: String? = nil, modifiers: Int = 0, glyph: Int? = nil,
            virtualKey: Int? = nil, enabled: Bool = true, mark: String = ""
        ) -> Node {
            let hasShortcut = character != nil || glyph != nil || virtualKey != nil
            return Node(
                title: title, isEnabled: enabled,
                shortcut: ShortcutAttributes(
                    character: character, virtualKey: virtualKey, glyph: glyph,
                    modifiers: hasShortcut ? modifiers : nil),
                mark: mark)
        }

        /// A menu that opens a submenu.
        static func menu(_ title: String, enabled: Bool = true, _ children: [Node]) -> Node {
            Node(title: title, isEnabled: enabled, children: children)
        }

        /// A separator line.
        static let separator = Node(title: "")
    }

    /// One running app and its menu bar. Nil for an app that shows no menu bar.
    struct App: Hashable, Sendable {
        var bundleID: String
        var processID: Int32
        var menuBar: [Node]?
    }

    private struct State {
        var apps: [String: App]
        /// Served for any app not in ``apps``, as the scenario sample is.
        var fallback: App?
        var accessGranted = true
        var costPerRead = Duration.zero
        var quitsAfterReads: Int?
        var revokesAccessAfterReads: Int?
        var closesLauncherAfterReads: Int?
        var failingTitles: Set<String> = []
        var walks = 0
        var reads = 0
        var frontmost: String?
        var activations: [String] = []
        var presses: [MenuItemRef] = []
        var onPress: (@Sendable (MenuItemRef) async -> Void)?
    }

    private let state: Mutex<State>
    private let listeners = Mutex<[Int: AsyncStream<Void>.Continuation]>([:])
    private let nextListener = Atomic<Int>(0)

    init(apps: [App], fallback: App? = nil) {
        state = Mutex(
            State(
                apps: Dictionary(apps.map { ($0.bundleID, $0) }, uniquingKeysWith: { _, last in last }),
                fallback: fallback))
    }

    // MARK: - Playing what a live app does

    var accessGranted: Bool {
        get { state.withLock { $0.accessGranted } }
        set { state.withLock { $0.accessGranted = newValue } }
    }

    /// Simulated time each element read takes. The walk's time limit counts it.
    var costPerRead: Duration {
        get { state.withLock { $0.costPerRead } }
        set { state.withLock { $0.costPerRead = newValue } }
    }

    /// The app being read quits after this many reads in one walk.
    var quitsAfterReads: Int? {
        get { state.withLock { $0.quitsAfterReads } }
        set { state.withLock { $0.quitsAfterReads = newValue } }
    }

    /// Accessibility goes away after this many reads in one walk.
    var revokesAccessAfterReads: Int? {
        get { state.withLock { $0.revokesAccessAfterReads } }
        set { state.withLock { $0.revokesAccessAfterReads = newValue } }
    }

    /// The launcher closes after this many reads in the next walk. It closes once, as a person
    /// closes it once, so the setting clears when a walk takes it.
    var closesLauncherAfterReads: Int? {
        get { state.withLock { $0.closesLauncherAfterReads } }
        set { state.withLock { $0.closesLauncherAfterReads = newValue } }
    }

    /// Elements with these titles fail to read, as an element that vanishes mid-walk does.
    var failingTitles: Set<String> {
        get { state.withLock { $0.failingTitles } }
        set { state.withLock { $0.failingTitles = newValue } }
    }

    /// Runs inside every press, after the app came to the front and before the item is found.
    var onPress: (@Sendable (MenuItemRef) async -> Void)? {
        get { state.withLock { $0.onPress } }
        set { state.withLock { $0.onPress = newValue } }
    }

    func setApp(_ app: App) {
        state.withLock { $0.apps[app.bundleID] = app }
    }

    func removeApp(_ bundleID: String) {
        state.withLock { _ = $0.apps.removeValue(forKey: bundleID) }
    }

    /// Tells every listener that the launcher closed.
    func simulateLauncherClosing() {
        for listener in listeners.withLock({ Array($0.values) }) { listener.yield() }
    }

    // MARK: - What happened

    /// Walks started, including those that failed.
    var walks: Int { state.withLock { $0.walks } }
    /// Elements read across all walks.
    var reads: Int { state.withLock { $0.reads } }
    /// Items pressed, in order.
    var presses: [MenuItemRef] { state.withLock { $0.presses } }
    /// Apps brought to the front before a press, in order.
    var activations: [String] { state.withLock { $0.activations } }
    /// The app in front, after the last press.
    var frontmost: String? { state.withLock { $0.frontmost } }
    /// Streams listening for the launcher to close.
    var closingListenerCount: Int { listeners.withLock { $0.count } }

    // MARK: - MenuReader

    @concurrent func readMenus(of app: MenuApp, limits: WalkLimits) async throws -> MenuSnapshot {
        let setup = state.withLock { state -> (App?, State) in
            state.walks += 1
            defer { state.closesLauncherAfterReads = nil }
            return (state.apps[app.bundleID] ?? state.fallback, state)
        }
        guard setup.1.accessGranted else { throw MenuReadError.accessMissing }
        guard let running = setup.0 else { throw MenuReadError.appNotRunning }
        guard running.menuBar != nil else { throw MenuReadError.noMenuBar }
        let run = Run(
            owner: self, bundleID: app.bundleID, app: running, cost: setup.1.costPerRead,
            quitsAfter: setup.1.quitsAfterReads, revokesAfter: setup.1.revokesAccessAfterReads,
            closesAfter: setup.1.closesLauncherAfterReads, failing: setup.1.failingTitles)
        return try MenuWalker.walk(
            run, app: app, processID: running.processID, limits: limits, elapsed: { run.elapsed },
            shouldStop: { Task.isCancelled || run.launcherClosed })
    }

    @concurrent func press(_ item: MenuItemRef) async throws {
        let (running, granted, hook, cost) = state.withLock { state in
            (state.apps[item.bundleID] ?? state.fallback, state.accessGranted, state.onPress, state.costPerRead)
        }
        guard granted else { throw MenuReadError.accessMissing }
        guard let running else { throw MenuReadError.appQuit }
        state.withLock { state in
            state.frontmost = item.bundleID
            state.activations.append(item.bundleID)
        }
        await hook?(item)
        let run = Run(owner: self, bundleID: item.bundleID, app: running, cost: cost)
        guard let found = try MenuWalker.find(item.path, in: run, elapsed: { run.elapsed }) else {
            throw MenuReadError.itemGone
        }
        guard found.isEnabled else { throw MenuReadError.itemDisabled }
        state.withLock { $0.presses.append(item) }
    }

    func launcherClosings() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = nextListener.add(1, ordering: .relaxed).newValue
        listeners.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.listeners.withLock { $0.removeValue(forKey: id) }
        }
        return stream
    }

    // MARK: - One walk

    /// The tree access for one walk or one press, counting reads and playing the configured events.
    private final class Run: MenuTreeAccess {
        let owner: SimulatedMenus
        let bundleID: String
        let app: App
        let cost: Duration
        let quitsAfter: Int?
        let revokesAfter: Int?
        let closesAfter: Int?
        let failing: Set<String>
        private(set) var elapsed = Duration.zero
        private(set) var launcherClosed = false
        private var count = 0

        init(
            owner: SimulatedMenus, bundleID: String, app: App, cost: Duration = .zero, quitsAfter: Int? = nil,
            revokesAfter: Int? = nil, closesAfter: Int? = nil, failing: Set<String> = []
        ) {
            self.owner = owner
            self.bundleID = bundleID
            self.app = app
            self.cost = cost
            self.quitsAfter = quitsAfter
            self.revokesAfter = revokesAfter
            self.closesAfter = closesAfter
            self.failing = failing
        }

        func menuBarItems() throws -> [Node] {
            guard let bar = app.menuBar else { throw MenuReadError.noMenuBar }
            return bar
        }

        func read(_ element: Node) throws -> MenuElementInfo<Node> {
            count += 1
            elapsed += cost
            owner.state.withLock { $0.reads += 1 }
            if let quitsAfter, count > quitsAfter {
                owner.removeApp(bundleID)
                throw MenuReadError.appQuit
            }
            if let revokesAfter, count > revokesAfter {
                owner.accessGranted = false
                throw MenuReadError.accessMissing
            }
            if failing.contains(element.title) { throw MenuReadError.elementFailed }
            if let closesAfter, count >= closesAfter, !launcherClosed {
                launcherClosed = true
                owner.simulateLauncherClosing()
            }
            return MenuElementInfo(
                title: element.title, isEnabled: element.isEnabled, shortcut: element.shortcut, mark: element.mark,
                children: element.children)
        }
    }
}

extension SimulatedMenus {
    /// The bundle ID of the sample app.
    static let sampleBundleID = "com.example.editor"

    /// A small editor's menu bar, served for whichever app is in front, so a scenario can search
    /// and press menu items with no real app.
    static func sample() -> SimulatedMenus {
        SimulatedMenus(
            apps: [], fallback: App(bundleID: sampleBundleID, processID: 4242, menuBar: sampleMenuBar))
    }

    /// The sample menu bar: an Apple menu, an app menu, File, Edit, View, Window and Help, with
    /// shortcuts, separators, a submenu, a checked item, a turned-off item and an Option alternate.
    static let sampleMenuBar: [Node] = [
        .menu(
            "Apple",
            [
                .item("About This Mac"), .separator, .item("System Settings…"), .separator,
                .item("Force Quit…", "\u{1B}", modifiers: MenuShortcut.optionBit), .separator,
                .item("Lock Screen", "Q", modifiers: MenuShortcut.controlBit),
                .item("Log Out", "Q", modifiers: MenuShortcut.shiftBit),
            ]),
        .menu(
            "Example Editor",
            [
                .item("About Example Editor"), .separator, .item("Settings…", ","), .separator,
                .item("Hide Example Editor", "H"), .item("Quit Example Editor", "Q"),
            ]),
        .menu(
            "File",
            [
                .item("New Document", "N"), .item("Open…", "O"),
                .menu("Open Recent", [.item("Draft"), .item("Notes"), .separator, .item("Clear Menu")]),
                .separator,
                .item("Close Window", "W"), .item("Close All", "W", modifiers: MenuShortcut.optionBit),
                .item("Save", "S"), .item("Save As…", "S", modifiers: MenuShortcut.shiftBit),
                .menu("Export", [.item("PDF…"), .item("PNG…"), .item("Plain Text…")]),
                .separator, .item("Print…", "P"),
            ]),
        .menu(
            "Edit",
            [
                .item("Undo", "Z"), .item("Redo", "Z", modifiers: MenuShortcut.shiftBit), .separator,
                .item("Cut", "X"), .item("Copy", "C"), .item("Paste", "V"),
                .item("Paste and Match Style", "V", modifiers: MenuShortcut.optionBit | MenuShortcut.shiftBit),
                .item("Delete", modifiers: MenuShortcut.noCommandBit, glyph: 0x17, enabled: false),
                .item("Select All", "A"), .separator,
                .menu(
                    "Find", [.item("Find…", "F"), .item("Find Next", "G"), .item("Find Previous", "G", modifiers: 1)]),
                .separator,
                .item("Emoji & Symbols", " ", modifiers: MenuShortcut.controlBit),
            ]),
        .menu(
            "View",
            [
                .item("Show Sidebar", "S", modifiers: MenuShortcut.controlBit, mark: "✓"),
                .item("Show Ruler", "R"), .separator,
                .item("Zoom In", "+"), .item("Zoom Out", "-"), .item("Actual Size", "0"), .separator,
                .item("Enter Full Screen", "F", modifiers: MenuShortcut.functionBit | MenuShortcut.noCommandBit),
            ]),
        .menu(
            "Window",
            [
                .item("Minimize", "M"), .item("Minimize All", "M", modifiers: MenuShortcut.optionBit),
                .item("Zoom"), .separator, .item("Bring All to Front"),
            ]),
        .menu("Help", [.item("Example Editor Help", "?")]),
    ]
}
