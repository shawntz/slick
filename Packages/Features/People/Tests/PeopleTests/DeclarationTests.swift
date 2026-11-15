import Foundation
import Kit
import KitTesting
import Testing

@testable import People

@Suite("Declarations", .timeLimit(.minutes(1)))
@MainActor
struct DeclarationTests {
    @Test func theManifestDeclaresContactsWithAReason() {
        let manifest = PeopleFeature.manifest
        #expect(manifest.id == "contacts")
        #expect(manifest.isEnabledByDefault)
        #expect(manifest.permissions.map(\.permission) == [.contacts])
        #expect(manifest.permissions.first?.reason.hasPrefix("Read ") == true)
        #expect(FeatureValidator.validate(manifest).isEmpty)
    }

    @Test func oneCommandThatOnlyOpensAList() async throws {
        let (harness, store) = await makeHarness()
        #expect(harness.feature.commands.map(\.id) == ["search"])
        let command = try harness.command("search")
        #expect(command.title == "Search Contacts")
        #expect(command.requires == [.contacts])
        #expect(command.confirmation == nil)
        // A deep link can run it, and all it does is open the list.
        let outcome = try await harness.run("search", launch: .deeplink)
        guard case .push = outcome else {
            Issue.record("Search Contacts did something other than open its list")
            return
        }
        #expect(harness.fakes.workspace.opened.isEmpty)
        #expect(harness.fakes.pasteboard.copied.isEmpty)
        #expect(store.peopleReads == 1)
        #expect(harness.issues.isEmpty)
    }

    @Test func everyRunOutsideTheAppGetsTheInMemoryStore() {
        for environment in RunEnvironment.allCases where !environment.touchesRealSystem {
            let context = FakeServices().context(featureID: "contacts", environment: environment)
            #expect(context.service(PeopleServiceKey.self) is InMemoryPeople, "\(environment)")
        }
        let harness = FeatureHarness(PeopleFeature.self)
        #expect(harness.feature.service is InMemoryPeople)
    }

    @Test func theInMemoryStoreHoldsInventedPeopleOnly() async throws {
        let people = try await InMemoryPeople(people: InMemoryPeople.sample).people()
        #expect(!people.isEmpty)
        for person in people {
            for email in person.emails {
                let domain = email.value.split(separator: "@").last.map(String.init) ?? ""
                #expect(domain.hasPrefix("example."), "\(email.value)")
            }
        }
    }

    @Test func theSettingsPaneOffersTheExpectedChoices() throws {
        let harness = FeatureHarness(PeopleFeature.self)
        let pane = try #require(harness.feature.settingsPane)
        let items = pane.sections.flatMap(\.items)
        #expect(
            items.map(\.title) == [
                "Show people in root search", "Return key", "Calls open in", "Allow Access to Contacts",
            ])
        #expect(items.compactMap(\.control.key?.name) == ["showsInRootSearch", "primaryAction", "callApp"])
        #expect(pane.sections.last?.footer?.contains(Brand.name) == true)
        #expect(harness.context.settings[PeopleSettings.showsInRootSearch])
        #expect(harness.context.settings[PeopleSettings.primaryAction] == .openInContacts)
        #expect(harness.context.settings[PeopleSettings.callApp].isEmpty)
    }

    @Test func titlesEndWithoutAFullStopAndMessagesAreSentences() {
        let titles = [
            Strings.Commands.search, Strings.List.noMatchesTitle, Strings.List.emptyTitle, Strings.Access.offTitle,
            Strings.Access.onTitle, Strings.Access.allow, Strings.Actions.call, Strings.Actions.openInMaps,
            Strings.Actions.copiedPhone, Strings.Failures.call, Strings.Failures.unreadable,
            Strings.Settings.allowAccess, Strings.Settings.searchSection, Strings.Settings.accessSection,
        ]
        for title in titles {
            #expect(!title.hasSuffix("."), "\(title)")
            #expect(title.first?.isUppercase == true, "\(title)")
        }
        let sentences = [
            Strings.summary, Strings.permissionReason, Strings.List.emptyMessage, Strings.Access.offMessage,
            Strings.Access.turnOnMessage, Strings.Access.restrictedMessage, Strings.Failures.openMessage,
            Strings.Settings.showsInRootSearchInfo, Strings.Settings.callAppInfo, Strings.Settings.allowAccessInfo,
            Strings.Settings.privacyNote, Strings.Settings.primaryActionInfo,
        ]
        for sentence in sentences {
            #expect(sentence.hasSuffix("."), "\(sentence)")
        }
    }
}
