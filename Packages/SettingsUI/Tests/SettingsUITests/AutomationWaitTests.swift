import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Testing

@testable import SettingsUI

/// A made-up feature that controls two apps over Automation: a player that is not running and a
/// helper that is, and offers the player's permission in its own pane.
final class PlayerSampleFeature: Feature {
    static let player = Permission.automation(bundleID: "com.example.player")
    static let helper = Permission.automation(bundleID: "com.example.helper")

    static let manifest = FeatureManifest(
        id: "player-sample", name: "Player Sample", icon: .symbol("play"),
        permissions: [
            PermissionNeed(player, reason: "Play and pause in Example Player."),
            PermissionNeed(helper, reason: "Ask Example Helper what plays."),
        ])

    init(context: FeatureContext) {}

    var settingsPane: SettingsPane? {
        SettingsPane([SettingsSection(items: [.permission(Self.player, info: "Play needs it.")])])
    }
}

/// Settings and onboarding never offer a button that would start an app to ask for Automation.
@MainActor @Suite(.timeLimit(.minutes(1))) struct AutomationWaitTests {
    static let sentence = "macOS asks the first time you control Example Player while it is open."

    /// A bed where the player is not running and the helper is, as Platform would report.
    func makeBed(status: PermissionStatus = .notDetermined, wired: Bool = true) -> (TestBed, SettingsContext) {
        let bed = TestBed(permissions: status)
        _ = bed.directory.register(PlayerSampleFeature.self, fakes: bed.fakes)
        bed.fakes.workspace.installed = [AppInfo(bundleID: "com.example.player", name: "Example Player")]
        var dependencies = bed.dependencies
        if wired {
            dependencies.permissionWaitsForApp = { $0 == PlayerSampleFeature.player }
        }
        let context = SettingsContext(dependencies)
        context.toasts.lifetime = .zero
        return (bed, context)
    }

    @Test func thePermissionsPaneSaysWhenMacOSAsksAndOffersNoButton() async {
        let (bed, context) = makeBed()
        let model = PermissionsModel(context: context)
        let player = model.entries.first { $0.permission == PlayerSampleFeature.player }
        let helper = model.entries.first { $0.permission == PlayerSampleFeature.helper }
        #expect(player?.waitingSentence == Self.sentence)
        #expect(helper?.waitingSentence == nil, "a running app can be asked")

        await model.grant(PlayerSampleFeature.player)
        #expect(bed.fakes.permissions.requests.isEmpty, "nothing asked, so nothing could start the app")
        #expect(bed.fakes.permissions.openedSettings.isEmpty)
        await model.grant(PlayerSampleFeature.helper)
        #expect(bed.fakes.permissions.requests == [PlayerSampleFeature.helper])
    }

    @Test func onboardingSaysWhenMacOSAsksAndAllowAsksNothing() async {
        let (bed, context) = makeBed()
        let model = OnboardingModel(context: context) {}
        let player = model.permissionItems.first { $0.permission == PlayerSampleFeature.player }
        #expect(player?.waitingSentence == Self.sentence)
        #expect(model.permissionItems.first { $0.permission == PlayerSampleFeature.helper }?.waitingSentence == nil)
        await model.allow(PlayerSampleFeature.player)
        #expect(bed.fakes.permissions.requests.isEmpty)
    }

    @Test func aFeaturesOwnPermissionItemWaitsToo() async throws {
        let (bed, context) = makeBed()
        let page = FeatureDetailModel(featureID: "player-sample", context: context)
        let item = try #require(page.sections.flatMap(\.items).first { $0.permission != nil })
        #expect(item.permissionWaitingSentence == Self.sentence)
        await item.grant()
        #expect(bed.fakes.permissions.requests.isEmpty)
    }

    @Test func aGrantedOrRefusedPermissionShowsNoSentence() async {
        let (_, granted) = makeBed(status: .granted)
        #expect(PermissionsModel(context: granted).entries.allSatisfy { $0.waitingSentence == nil })

        // A refusal opens System Settings, which starts no app.
        let (bed, denied) = makeBed(status: .denied)
        let model = PermissionsModel(context: denied)
        #expect(model.entries.allSatisfy { $0.waitingSentence == nil })
        await model.grant(PlayerSampleFeature.player)
        #expect(bed.fakes.permissions.requests.isEmpty)
        #expect(bed.fakes.permissions.openedSettings == [PlayerSampleFeature.player])
    }

    /// Until App passes Platform's answer, every Automation permission waits, so no button can
    /// start an app. An app the workspace does not know reads as "this app".
    @Test func theDefaultLetsNoAutomationButtonAsk() async {
        let (bed, context) = makeBed(wired: false)
        let model = PermissionsModel(context: context)
        let automation = model.entries.filter {
            if case .automation = $0.permission { return true }
            return false
        }
        #expect(automation.count == 2)
        #expect(automation.allSatisfy { $0.waitingSentence != nil })
        #expect(
            automation.first { $0.permission == PlayerSampleFeature.helper }?.waitingSentence
                == "macOS asks the first time you control this app while it is open.")
        #expect(model.entries.first { $0.permission == .accessibility }?.waitingSentence == nil)
        await model.grant(PlayerSampleFeature.helper)
        #expect(bed.fakes.permissions.requests.isEmpty)
        #expect(SettingsDependencies.everyAutomationWaits(PlayerSampleFeature.player))
        #expect(!SettingsDependencies.everyAutomationWaits(.accessibility))
    }

    @Test func aHostGrantFlowIsNotRunForAPermissionThatWaits() async {
        let (bed, _) = makeBed()
        var asked: [Permission] = []
        var dependencies = bed.dependencies
        dependencies.permissionWaitsForApp = { $0 == PlayerSampleFeature.player }
        dependencies.grantPermission = { permission in
            asked.append(permission)
            return .granted
        }
        let model = PermissionsModel(context: SettingsContext(dependencies))
        await model.grant(PlayerSampleFeature.player)
        #expect(asked.isEmpty)
        await model.grant(PlayerSampleFeature.helper)
        #expect(asked == [PlayerSampleFeature.helper])
    }
}
