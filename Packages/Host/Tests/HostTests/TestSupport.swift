import AppKit
import Foundation
import Host
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI

/// Records what the pipeline asks of the panel, so runtime tests run with no window.
@MainActor final class RecordingPresenter: RunPresenter {
    var isPanelVisible = true
    var sessionID = 1
    var confirmAnswer = true
    var permissionAnswer = true
    private(set) var toasts: [Toast] = []
    private(set) var toastIDs: [ToastID] = []
    private(set) var toastOrigins: [RunOrigin?] = []
    private(set) var huds: [HUD] = []
    private(set) var confirmations: [Confirmation] = []
    private(set) var permissionCards: [(permission: Permission, feature: String, reason: String)] = []
    private(set) var outcomes: [String] = []
    private(set) var reloads = 0
    private(set) var queries: [String] = []
    private(set) var dismissals = 0

    func showToast(_ toast: Toast, id: ToastID, origin: RunOrigin?) {
        toasts.append(toast)
        toastIDs.append(id)
        toastOrigins.append(origin)
    }

    func dismissToast(_ id: ToastID) {}

    func showHUD(_ hud: HUD) {
        huds.append(hud)
    }

    func confirm(_ confirmation: Confirmation, isDestructive: Bool) async -> Bool {
        confirmations.append(confirmation)
        return confirmAnswer
    }

    func askForPermission(_ permission: Permission, featureName: String, reason: String) async -> Bool {
        permissionCards.append((permission, featureName, reason))
        return permissionAnswer
    }

    func apply(_ outcome: ActionOutcome, origin: RunOrigin) {
        switch outcome {
        case .close(let hud):
            outcomes.append("close")
            isPanelVisible = false
            if let hud { huds.append(hud) }
        case .push: outcomes.append("push")
        case .replace: outcomes.append("replace")
        case .pop: outcomes.append("pop")
        case .popToRoot: outcomes.append("popToRoot")
        case .showRoot(let query): outcomes.append("showRoot:" + query)
        case .keepOpen, .run, .needsPermission: outcomes.append("unexpected")
        }
    }

    func reloadTopPage() {
        reloads += 1
    }

    func setQuery(_ text: String) {
        queries.append(text)
    }

    func quickLook(_ urls: [URL]) {}
    func share(_ items: [ShareItem]) {}

    func dismissPanel() {
        dismissals += 1
        isPanelVisible = false
    }
}

/// HUDs recorded instead of shown.
@MainActor final class RecordingHUD: HUDDisplay {
    private(set) var shown: [HUD] = []
    func show(_ hud: HUD) { shown.append(hud) }
    func prewarm() {}
    func apply(_ theme: Theme) {}
}

/// A feature with one command per pipeline rule.
final class Workbench: Feature {
    static let manifest = FeatureManifest(
        id: "workbench", name: "Workbench", icon: .glyph("W"),
        permissions: [PermissionNeed(.accessibility, reason: "Move the windows you pick.")])
    static let relayed = ItemID.command(feature: "relay", command: "receive")

    let declarations = ChangeSignal()
    /// The live subtitle's signal, one object for the life of the feature, as Scripts keeps it.
    let statusChanges = ChangeSignal()
    var showsExtra = false
    var showsEcho = true
    private(set) var log: [String] = []
    private(set) var launches: [LaunchSource] = []
    private(set) var arguments: [CommandArguments] = []
    private(set) var queries: [String] = []
    private(set) var presses: [Int] = []
    private(set) var activations = 0
    private(set) var deactivations = 0
    /// How often Toolkit's row actions were built.
    private(set) var rowActionBuilds = 0
    let shelf = Shelf()
    let ledger = Ledger()
    let context: FeatureContext

    init(context: FeatureContext) {
        self.context = context
    }

    var declarationChanges: ChangeSignal? { declarations }

    func activate() async { activations += 1 }
    func deactivate() async { deactivations += 1 }

    var commands: [Command] {
        var commands = [
            Command(id: "plain", title: "Plain") { context in
                self.record("plain", context)
                return .close(hud: "Done")
            },
            Command(id: "slow", title: "Slow") { context in
                let count = self.presses.count
                try await context.clock.sleep(for: .seconds(1))
                self.presses.append(count)
                return .keepOpen
            },
            Command(id: "once", title: "Once", runPolicy: .dropWhileRunning) { context in
                try await context.clock.sleep(for: .seconds(1))
                return .keepOpen
            },
            Command(id: "wait", title: "Wait", runPolicy: .concurrent) { context in
                self.log.append("wait started")
                try await context.clock.sleep(for: .seconds(600))
                self.log.append("wait finished")
                return .keepOpen
            },
            Command(id: "fail", title: "Fail") { _ in
                throw ActionFailure("Could not reach the server", message: "Timed out")
            },
            Command(id: "cancelled", title: "Cancelled") { _ in throw CancellationError() },
            Command(id: "guarded", title: "Guarded", requires: [.accessibility]) { context in
                self.record("guarded", context)
                return .keepOpen
            },
            Command(id: "automate", title: "Automate") { context in
                guard context.permissions.isGranted(.accessibility) else { return .needsPermission(.accessibility) }
                self.record("automate", context)
                return .keepOpen
            },
            Command(
                id: "clear", title: "Clear",
                confirmation: Confirmation("Clear everything?", confirmTitle: "Clear", suppressionKey: "clear")
            ) { context in
                self.record("clear", context)
                return .keepOpen
            },
            Command(id: "hand-off", title: "Hand Off") { _ in
                .run(Self.relayed, arguments: ["text": "long", "extra": "kept"])
            },
            Command(id: "nowhere", title: "Nowhere") { _ in .run(.command(feature: "missing", command: "gone")) },
            Command(id: "toast", title: "Toast") { context in
                context.showToast(
                    Toast(
                        .info, "Saved",
                        action: ToastAction("Undo") { context in
                            self.record("undo", context)
                            return .keepOpen
                        }))
                return .keepOpen
            },
            Command(id: "eject", title: "Eject") { context in
                guard
                    await context.confirm(
                        Confirmation("Eject 2 disks?", confirmTitle: "Eject", suppressionKey: "eject-all"))
                else { return .keepOpen }
                self.record("eject", context)
                return .keepOpen
            },
            Command(id: "reloading", title: "Reloading") { context in
                context.reload()
                return .keepOpen
            },
            Command(id: "open-shelf", title: "Open Shelf") { _ in .push(.list(ListPage(self.shelf, title: "Shelf"))) },
            Command(id: "open-untitled", title: "Browse Shelf") { _ in .push(.list(ListPage(self.shelf))) },
            Command(id: "open-ledger", title: "Open Ledger") { _ in .push(.list(ListPage(self.ledger, title: "Ledger")))
            },
            Command(id: "again", title: "Again") { _ in .showRoot(query: "12 * 3") },
            Command(id: "survey", title: "Survey") { _ in .push(.form(Self.survey)) },
            Command(id: "late-push", title: "Late Push", runPolicy: .concurrent) { context in
                try await context.clock.sleep(for: .seconds(1))
                return .push(.list(ListPage(self.shelf, title: "Shelf")))
            },
            Command(id: "late-close", title: "Late Close", runPolicy: .concurrent) { context in
                try await context.clock.sleep(for: .seconds(1))
                return .close(hud: "Done Later")
            },
            Command(id: "stubborn", title: "Stubborn", runPolicy: .concurrent) { context in
                // Ignores cancellation on purpose, as a careless handler would.
                try? await context.clock.sleep(for: .seconds(1))
                self.log.append("stubborn finished")
                return .push(.list(ListPage(self.shelf, title: "Shelf")))
            },
            Command(id: "form", title: "Form") { _ in
                .push(.form(FormPage(title: "New Item", fields: []) { _, _ in .pop }))
            },
            // As Snippets' Fill In Snippet: a keyword typed in another app pastes at once, or asks
            // in a form first when its snippet has blanks.
            Command(id: "fill", title: "Fill In", requires: [.accessibility], showsInRoot: false) { context in
                self.record("fill", context)
                if context.arguments["snippet"] == "plain", context.launch == .textExpansion {
                    try await context.pasteboard.paste("Plain text")
                    return .close()
                }
                return .push(.form(Self.fillForm))
            },
            Command(
                id: "act-now", title: "Act Now", showsInRoot: false, runPolicy: .concurrent, allowsDeepLinks: false
            ) { context in
                self.record("act-now", context)
                return .keepOpen
            },
            // As Clipboard's Paste: the handler closes the panel, the pasteboard closes it again,
            // and the outcome closes it a third time.
            Command(id: "close-twice", title: "Close Twice") { context in
                context.dismiss()
                context.dismiss()
                return .close(hud: "Pasted")
            },
            Command(
                id: "status", title: "Status",
                liveSubtitle: LiveSubtitle(every: .seconds(60), changes: statusChanges) { "Ready" }
            ) { _ in .keepOpen },
            // A command with row actions and no arguments, as most commands are.
            Command(id: "toolkit", title: "Toolkit") { _ in .keepOpen }.withRowActions {
                self.rowActionBuilds += 1
                return [
                    Action("Open Toolkit Folder", id: "folder") { _ in .keepOpen },
                    Action("Copy Toolkit Path", id: "copy-path", shortcut: .copy) { _ in .keepOpen },
                    .runCommand(Self.relayed, title: "Send Toolkit to Relay"),
                ]
            },
            Command(id: "ask-echo", title: "Ask Echo") { _ in
                .run(RuntimeFixture.command("echo"), arguments: ["kept": "yes"])
            },
        ]
        if showsEcho {
            commands.append(
                Command(
                    id: "echo", title: "Echo",
                    arguments: [
                        CommandArgument("text"), CommandArgument("mode", isOptional: true, defaultValue: "plain"),
                    ]
                ) { context in
                    self.record("echo", context)
                    return .keepOpen
                }.withRowActions {
                    [
                        Action("Edit Echo", id: "edit") { context in
                            self.record("edit-echo", context)
                            return .keepOpen
                        },
                        .runCommand(Self.relayed, title: "Send to Relay"),
                    ]
                })
        }
        if showsExtra { commands.append(Command(id: "extra", title: "Extra") { _ in .keepOpen }) }
        return commands
    }

    /// A form with a required field, a validator and a toast on submit.
    static let survey = FormPage(
        title: "Survey",
        fields: [
            .text("name", title: "Name", placeholder: "Your name", isRequired: true),
            .checkbox("agree", title: "Terms", label: "I agree"),
        ],
        submitTitle: "Send",
        validate: { values in
            let name = values.text("name")
            return name.count < 3 ? ["name": FieldError("Too short", range: 0..<name.utf16.count)] : [:]
        },
        submit: { values, context in
            context.showToast(.success("Thanks, \(values.text("name"))"))
            return .pop
        })

    /// The form Fill In shows: one blank, then a paste into the app that was in front.
    static let fillForm = FormPage(
        title: "Fill In", fields: [.text("name", title: "Name", isRequired: true)], submitTitle: "Paste"
    ) { values, context in
        try await context.pasteboard.paste("Hello " + values.text("name"))
        return .close()
    }

    private func record(_ name: String, _ context: ActionContext) {
        log.append(name)
        launches.append(context.launch)
        arguments.append(context.arguments)
        queries.append(context.query)
    }
}

/// A second feature: the target of hand-offs, and a universal action for text.
final class Relay: Feature {
    static let manifest = FeatureManifest(id: "relay", name: "Relay", icon: .glyph("R"))
    private(set) var received: [CommandArguments] = []
    private(set) var launches: [LaunchSource] = []
    private(set) var shouted: [String] = []

    init(context: FeatureContext) {}

    var commands: [Command] {
        [
            Command(id: "receive", title: "Receive", arguments: [CommandArgument("text")]) { context in
                self.received.append(context.arguments)
                self.launches.append(context.launch)
                return .keepOpen
            }
        ]
    }

    var universalActions: [UniversalActionProvider] {
        [
            .text { text in
                [
                    Action("Shout", id: "shout") { context in
                        self.shouted.append(context.query)
                        return .keepOpen
                    }
                ]
            }
        ]
    }
}

/// A feature that is off until the user turns it on.
final class Watcher: Feature {
    static let manifest = FeatureManifest(
        id: "watcher", name: "Watcher", icon: .glyph("E"), isEnabledByDefault: false)
    private(set) var activations = 0
    init(context: FeatureContext) {}
    func activate() async { activations += 1 }
}

/// Setting keys of the test features.
nonisolated enum ShelfSettings {
    static let sort = SettingKey("sort", default: "name")
}

/// A host-filtered list with a Recent section, rank hints, counts and a change signal.
@MainActor final class Shelf: ListSource {
    let changes: ChangeSignal? = ChangeSignal()
    var reloadsOnSettings: [AnySettingKey] { [ShelfSettings.sort.erased] }
    var items = ["Apple", "Apple Pie", "Banana", "Cherry"]
    var refreshAfter: Duration?
    private(set) var requests: [ListRequest] = []

    func load(_ request: ListRequest) async throws -> ListResult {
        requests.append(request)
        let rows = items.map { title in
            Row(
                id: ItemID("shelf", title.lowercased()), title: title, icon: .symbol("square"),
                rankHint: title == "Apple Pie" ? 2 : 0)
        }
        return ListResult(
            sections: [
                ListSection("Recent", id: "recent", visibility: .whenQueryEmpty, rows: Array(rows.prefix(1))),
                ListSection("All", id: "all", showsCount: true, rows: rows),
            ],
            refreshAfter: refreshAfter,
            emptyState: EmptyState(title: "Nothing on the Shelf"))
    }

    func actions(for row: Row) -> [Action] {
        [
            Action("Take", id: "take") { _ in .keepOpen },
            Action("Inspect", id: "inspect") { _ in .keepOpen },
        ]
    }
}

/// A custom-filtered list that loads per query, in pages of two.
@MainActor final class Ledger: ListSource {
    var entries = (1...7).map { "Entry \($0)" }
    private(set) var requests: [ListRequest] = []
    var filtering: ListFiltering { .custom(debounce: .zero) }

    func load(_ request: ListRequest) async throws -> ListResult {
        requests.append(request)
        let start = request.page.flatMap { Int($0.value) } ?? 0
        let matching = entries.filter { request.query.isEmpty || $0.contains(request.query) }
        let page = matching.dropFirst(start).prefix(2)
        let rows = page.map { Row(id: ItemID("ledger", $0), title: $0, titleHighlights: [0..<1]) }
        let next = start + 2 < matching.count ? ListPageToken(String(start + 2)) : nil
        return ListResult(sections: [ListSection("All", rows: rows)], nextPage: next)
    }

    func actions(for row: Row) -> [Action] { [] }
}

/// Builds a runtime over fakes with the test features registered and active.
@MainActor struct RuntimeFixture {
    let fakes: FakeServices
    let runtime: FeatureRuntime
    let presenter = RecordingPresenter()
    let dataDirectory: URL

    init(fakes: FakeServices = FakeServices(), dataDirectory: URL? = nil) {
        self.fakes = fakes
        self.dataDirectory = dataDirectory ?? fakes.storage.root.appending(path: "host", directoryHint: .isDirectory)
        runtime = FeatureRuntime(services: fakes.services, environment: .selftest, dataDirectory: self.dataDirectory)
        runtime.pipeline.presenter = presenter
    }

    func start() async {
        await runtime.start([
            FeatureRegistration(Workbench.self), FeatureRegistration(Relay.self), FeatureRegistration(Watcher.self),
        ])
    }

    var workbench: Workbench { runtime.instance("workbench") as! Workbench }
    var relay: Relay { runtime.instance("relay") as! Relay }

    static func command(_ name: String) -> ItemID { .command(feature: "workbench", command: name) }
}

/// A value a sendable closure can change on the main actor.
@MainActor final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Waits until a condition holds, checking every millisecond, for at most two seconds.
@MainActor func waitUntil(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<2000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

/// Rows for root search: commands of the test features, an app and a file.
enum SampleRows {
    static let echo = Row(
        id: .command(feature: "workbench", command: "echo"), title: "Echo", subtitle: "Workbench",
        icon: .symbol("text.bubble"))
    static let plain = Row(
        id: .command(feature: "workbench", command: "plain"), title: "Plain", subtitle: "Workbench",
        icon: .symbol("circle"))
    static let shelf = Row(
        id: .command(feature: "workbench", command: "open-shelf"), title: "Open Shelf", subtitle: "Workbench",
        icon: .symbol("books.vertical"))
    static let editor = Row(
        id: ItemID("app", "com.example.editor"), title: "Example Editor", subtitle: "Application",
        icon: .app(bundleID: "com.example.editor"), completion: nil)
    static let note = Row(
        id: ItemID("file", "/tmp/example/notes.txt"), title: "Notes", subtitle: "~/example",
        icon: .fileType("txt"), accessories: [.tag("Text", color: .blue), .shortcut(KeyCombo(.n, .command))],
        represents: .text("notes"))
    static let search = Row(
        id: .command(feature: "relay", command: "receive"), title: "Receive", subtitle: "Relay",
        icon: .symbol("tray.and.arrow.down"))

    static let toolkit = Row(
        id: .command(feature: "workbench", command: "toolkit"), title: "Toolkit", subtitle: "Workbench",
        icon: .symbol("wrench"))

    static let survey = Row(
        id: .command(feature: "workbench", command: "survey"), title: "Survey", subtitle: "Workbench",
        icon: .symbol("list.clipboard"))

    static var all: [Row] { [echo, plain, shelf, editor, note] }
}
