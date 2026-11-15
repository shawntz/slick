import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Testing

@testable import SettingsUI

@MainActor @Suite(.timeLimit(.minutes(1))) struct PermissionsModelTests {
    @Test func listsEveryPermissionWithTheFeaturesThatWantIt() {
        let bed = TestBed(permissions: .notDetermined)
        let model = PermissionsModel(context: bed.context())
        let entries = model.entries
        #expect(entries.map(\.permission) == [.accessibility, .inputMonitoring, .screenRecording])
        #expect(entries[0].wants.map(\.featureName) == ["Sample Tools", "Window Helper"])
        #expect(
            entries[0].wants.map(\.reason) == [
                "Paste the chosen sample into the frontmost app.", "Move the windows you pick.",
            ])
        #expect(entries[0].wants.map(\.isFeatureEnabled) == [true, false])
        #expect(entries.allSatisfy { $0.status == .notDetermined })
        #expect(bed.fakes.permissions.requests.isEmpty)
    }

    @Test func statusIsLive() {
        let bed = TestBed(permissions: .notDetermined)
        let model = PermissionsModel(context: bed.context())
        bed.fakes.permissions.set(.screenRecording, to: .granted)
        #expect(model.entries.first { $0.permission == .screenRecording }?.status == .granted)
    }

    @Test func watchFollowsChangesWhileThePaneIsVisible() async {
        let bed = TestBed(permissions: .notDetermined)
        let model = PermissionsModel(context: bed.context())
        let watching = Task { await model.watch() }
        #expect(await eventually { true })
        bed.fakes.permissions.set(.inputMonitoring, to: .granted)
        await bed.fakes.settle()
        watching.cancel()
        await watching.value
        #expect(model.entries.first { $0.permission == .inputMonitoring }?.status == .granted)
    }

    @Test func grantRequestsOnlyThatPermission() async {
        let bed = TestBed(permissions: .notDetermined)
        let model = PermissionsModel(context: bed.context())
        await model.grant(.screenRecording)
        #expect(bed.fakes.permissions.requests == [.screenRecording])
        await model.openSettings(for: .accessibility)
        #expect(bed.fakes.permissions.openedSettings == [.accessibility])
    }

    @Test func fullDiskAccessOpensSystemSettings() async {
        let bed = TestBed(permissions: .notDetermined)
        let grant = bed.context().permissions
        _ = await grant.grant(.fullDiskAccess)
        #expect(bed.fakes.permissions.requests.isEmpty)
        #expect(bed.fakes.permissions.openedSettings == [.fullDiskAccess])
    }

    @Test func aHostGrantFlowReplacesTheDefault() async {
        let bed = TestBed(permissions: .notDetermined)
        var asked: [Permission] = []
        var dependencies = bed.dependencies
        dependencies.grantPermission = { permission in
            asked.append(permission)
            return .granted
        }
        let model = PermissionsModel(context: SettingsContext(dependencies))
        await model.grant(.accessibility)
        #expect(asked == [.accessibility])
        #expect(bed.fakes.permissions.requests.isEmpty)
    }
}
