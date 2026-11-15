import Foundation
import Kit
import KitTesting
import Testing

/// A list of the app in front, as Menu Items has, that hears when its page shows again and when the
/// panel closes. It reads again on each show by sending its own signal.
final class FrontAppList: ListSource, PageEvents {
    let signal = ChangeSignal()
    var front = "Sample Editor"
    private(set) var loads = 0
    private(set) var events: [String] = []

    var changes: ChangeSignal? { signal }

    func load(_ request: ListRequest) async throws -> ListResult {
        loads += 1
        return ListResult(rows: [Row(id: ItemID("front", front), title: front)])
    }

    func actions(for row: Row) -> [Action] {
        [
            Action("Press Item") { _ in .close() },
            Action.push("Show Details") { .detail(DetailPage(detail: .markdown("Details"))) },
        ]
    }

    func pageWillShowAgain(_ reason: PageShowReason) {
        events.append(reason == .panelOpened ? "opened" : "returned")
        signal.send()
    }

    func panelDidClose() {
        events.append("closed")
    }
}

/// A list that adopts nothing, to show that the events cost a plain source nothing.
final class PlainList: ListSource {
    private(set) var loads = 0

    func load(_ request: ListRequest) async throws -> ListResult {
        loads += 1
        return ListResult(rows: [Row(id: ItemID("plain", "1"), title: "Plain Row")])
    }

    func actions(for row: Row) -> [Action] { [] }
}

final class FrontAppFeature: Feature {
    static let manifest = FeatureManifest(
        id: "front-app", name: "Front App", icon: .symbol("menubar.rectangle"),
        permissions: [PermissionNeed(.accessibility, reason: "Read the menus of the app in front.")])

    let list = FrontAppList()
    let plain = PlainList()
    private(set) var grants: [Permission] = []

    init(context: FeatureContext) {}

    var commands: [Command] {
        [
            Command(id: "menus", title: "Search Menu Items") { [list] _ in .push(.list(ListPage(list))) },
            Command(id: "plain", title: "Plain List") { [plain] _ in .push(.list(ListPage(plain))) },
            Command(id: "press", title: "Press Menu Item", requires: [.accessibility]) { _ in .close() },
        ]
    }

    func permissionGranted(_ permission: Permission) async {
        grants.append(permission)
    }
}

@Suite("Panel events and grants in the harness", .timeLimit(.minutes(1)))
struct PanelEventsTests {
    @Test func aPageHearsThePanelCloseAndOpenAndReadsAgain() async throws {
        let harness = FeatureHarness(FrontAppFeature.self)
        let list = harness.feature.list
        try await harness.run("menus")
        #expect(list.loads == 1)

        harness.closePanel()
        harness.closePanel()
        #expect(list.events == ["closed"])
        #expect(harness.isClosed)

        list.front = "Sample Viewer"
        try await harness.openPanel()
        #expect(list.events == ["closed", "opened"])
        #expect(list.loads == 2)
        #expect(harness.rows.map(\.title) == ["Sample Viewer"])
        #expect(harness.issues.isEmpty)
    }

    @Test func goingBackTellsThePageBelowAndClosingTellsEveryPage() async throws {
        let harness = FeatureHarness(FrontAppFeature.self)
        let list = harness.feature.list
        try await harness.run("menus")
        try await harness.perform("Show Details")
        #expect(harness.pages.count == 2)

        try await harness.goBack()
        #expect(list.events == ["returned"])
        #expect(list.loads == 2)

        try await harness.perform("Press Item")
        #expect(harness.isClosed)
        #expect(list.events == ["returned", "closed"])
    }

    @Test func aSourceThatAdoptsNothingIsLoadedOnlyWhenItChanged() async throws {
        let harness = FeatureHarness(FrontAppFeature.self)
        try await harness.run("plain")
        harness.closePanel()
        try await harness.openPanel()
        #expect(harness.feature.plain.loads == 1)
        await #expect(throws: HarnessError.self) {
            try await harness.goBack()
            try await harness.goBack()
        }
    }

    @Test func aGrantInSettingsTellsTheFeatureWithoutAStream() async throws {
        let fakes = FakeServices()
        fakes.permissions.set(.accessibility, to: .notDetermined)
        let harness = FeatureHarness(FrontAppFeature.self, fakes: fakes)
        try await harness.grantInSettings(.contacts)
        #expect(harness.feature.grants.isEmpty)
        try await harness.grantInSettings(.accessibility)
        try await harness.grantInSettings(.accessibility)
        #expect(harness.feature.grants == [.accessibility])
        #expect(fakes.permissions.status(of: .accessibility) == .granted)
        #expect(fakes.permissions.openStreamCount == 0)
    }

    @Test func aGrantOnThePanelsCardTellsTheFeatureToo() async throws {
        let fakes = FakeServices()
        fakes.permissions.set(.accessibility, to: .notDetermined)
        let harness = FeatureHarness(FrontAppFeature.self, fakes: fakes)
        await #expect(throws: HarnessError.self) { try await harness.run("press") }
        #expect(harness.feature.grants.isEmpty)
        harness.grantsMissingPermissions = true
        try await harness.run("press")
        #expect(harness.feature.grants == [.accessibility])
    }
}
