import Foundation
import Kit
import KitTesting
import Testing

@testable import SystemCommands

@Suite("Declarations", .timeLimit(.minutes(1)))
@MainActor
struct DeclarationTests {
    static let commandIDs = [
        "sleep", "sleep-displays", "lock-screen", "start-screen-saver", "log-out", "restart", "shut-down",
        "open-trash", "empty-trash", "eject-all-disks", "toggle-hidden-files", "toggle-dark-mode", "mute", "unmute",
        "toggle-mute", "volume-up", "volume-down", "set-volume", "kill-process",
    ]

    @Test func declaresEveryCommandOnceAndNothingTheAppsFeatureOwns() {
        let system = SystemHarness()
        let ids = system.harness.feature.commands.map(\.id)
        #expect(ids == Self.commandIDs)
        #expect(!ids.contains("quit-all"))
        #expect(system.harness.issues.isEmpty)
    }

    @Test func titlesUseTitleCaseAndHotkeysAreLeftToTheUser() {
        let commands = SystemHarness().harness.feature.commands
        for command in commands {
            let words = command.title.split(separator: " ")
            #expect(words.allSatisfy { $0.first?.isUppercase == true }, "\(command.title)")
            #expect(command.suggestedHotkey == nil)
            #expect(!command.keywords.isEmpty, "\(command.id) has keywords")
        }
    }

    @Test(arguments: [
        ("restart", "reboot"), ("shut-down", "shutdown"), ("shut-down", "power off"), ("log-out", "logout"),
        ("log-out", "sign out"), ("sleep-displays", "sleepdisplays"), ("start-screen-saver", "screensaver"),
        ("empty-trash", "emptytrash"), ("open-trash", "trash"), ("eject-all-disks", "ejectall"), ("volume-up", "volup"),
        ("volume-down", "voldown"), ("toggle-dark-mode", "light mode"), ("toggle-hidden-files", "dotfiles"),
        ("kill-process", "force quit"), ("kill-process", "activity monitor"), ("lock-screen", "lock"),
    ])
    func commandsAnswerTheWordsPeopleType(id: String, word: String) throws {
        let command = try SystemHarness().harness.command(id)
        #expect(command.keywords.contains(word))
    }

    @Test func onlyTheSessionCommandsDeclareAConfirmationAndItCannotBeSilenced() {
        let commands = SystemHarness().harness.feature.commands
        let confirmed = commands.filter { $0.confirmation != nil }
        #expect(confirmed.map(\.id) == ["log-out", "restart", "shut-down"])
        for command in confirmed {
            #expect(command.confirmation?.suppressionKey == nil)
            #expect(command.confirmation?.isDestructive == true)
            #expect(command.confirmation?.confirmTitle == command.title)
        }
    }

    @Test func setVolumeTakesOneRequiredArgument() throws {
        let command = try SystemHarness().harness.command("set-volume")
        #expect(command.arguments.map(\.name) == ["level"])
        #expect(command.arguments.first?.isOptional == false)
        #expect(command.arguments.first?.placeholder == "0 to 100")
    }

    @Test func theManifestGivesAReasonForEachPermission() {
        let manifest = SystemFeature.manifest
        #expect(manifest.id == "system")
        #expect(
            manifest.permissions.map(\.permission) == [
                .automation(bundleID: "com.apple.finder"), .automation(bundleID: "com.apple.systemevents"),
                .automation(bundleID: "com.apple.loginwindow"),
            ])
        let verbs: Set<Substring> = ["Count", "Switch", "Ask"]
        for need in manifest.permissions {
            #expect(need.reason.split(separator: " ").first.map(verbs.contains) == true, "\(need.reason)")
            #expect(need.reason.hasSuffix("."))
        }
    }

    @Test func theSettingsPaneOffersEachChoiceWithASafeDefault() throws {
        let system = SystemHarness()
        let pane = try #require(system.harness.feature.settingsPane)
        #expect(pane.sections.map(\.title) == ["Sound", "Disks", "Kill Process", "Permissions"])
        let keys = pane.sections.flatMap(\.items).compactMap(\.control.key?.name)
        #expect(
            keys == [
                "volumeStep", "ejectsNetworkVolumes", "neverEject", "processSort", "processRefresh",
                "showsBackgroundProcesses",
            ])
        let settings = system.settings
        #expect(settings[SystemSettings.volumeStep] == .keys)
        #expect(settings[SystemSettings.ejectsNetworkVolumes] == false)
        #expect(settings[SystemSettings.neverEject].isEmpty)
        #expect(settings[SystemSettings.processSort] == .cpu)
        #expect(settings[SystemSettings.processRefresh] == .twoSeconds)
        #expect(settings[SystemSettings.showsBackgroundProcesses] == true)
        let permissions = pane.sections.last?.items.compactMap { item -> Permission? in
            if case .permission(let permission) = item.control { return permission }
            return nil
        }
        #expect(permissions == SystemFeature.manifest.permissions.map(\.permission))
    }

    @Test func theIsolatedServicesTouchNothingReal() {
        let context = FakeServices().context(featureID: "system", environment: .scenario)
        #expect(context.service(PowerServiceKey.self) is SimulatedPower)
        #expect(context.service(HousekeepingServiceKey.self) is SimulatedHousekeeping)
        #expect(context.service(AppearanceServiceKey.self) is SimulatedAppearance)
        #expect(context.service(SoundServiceKey.self) is SimulatedSound)
        #expect(context.service(ProcessTableKey.self) is SimulatedProcessTable)
    }

    @Test func theAppleEventCodesMatchTheDictionary() {
        #expect(AppleEvents.fourCharCode("thme") == 0x7468_6D65)
        #expect(AppleEvents.fourCharCode("aprp") == 0x6170_7270)
    }
}
