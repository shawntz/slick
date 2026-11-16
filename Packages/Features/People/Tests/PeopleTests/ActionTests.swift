import Foundation
import Kit
import KitTesting
import Testing

@testable import People

@Suite("Actions", .timeLimit(.minutes(1)))
@MainActor
struct ActionTests {
    /// Opens the list and selects one person.
    private func select(_ person: Person, among people: [Person] = Cast.all) async throws -> (
        FeatureHarness<PeopleFeature>, InMemoryPeople
    ) {
        let (harness, store) = await makeHarness(people: people)
        try await harness.run("search")
        try harness.select(personID(person))
        return (harness, store)
    }

    @Test func actionsFollowWhatThePersonHas() async throws {
        let (harness, _) = try await select(Cast.ana)
        #expect(
            harness.actionIDs == [
                "open-in-contacts", "call", "message", "email", "facetime", "facetime-audio", "open-address-in-maps",
                "large-type-phone", "copy-name", "copy-phone", "copy-email", "copy-address",
            ])
        try harness.select(personID(Cast.lea))
        #expect(harness.actionIDs == ["open-in-contacts", "copy-name"])
        try harness.select(personID(Cast.bakery))
        #expect(
            harness.actionIDs == [
                "open-in-contacts", "call", "message", "facetime", "facetime-audio", "open-address-in-maps",
                "large-type-phone", "copy-name", "copy-phone", "copy-address",
            ])
        #expect(harness.issues.isEmpty)
    }

    @Test func oneNumberCallsAtOnce() async throws {
        let (harness, _) = try await select(Cast.bruno)
        let outcome = try await harness.perform("call")
        #expect(outcome.kind == .close(hud: nil))
        #expect(harness.fakes.workspace.opened == [URL(string: "tel:5550100")])
    }

    @Test func severalNumbersGetASubmenuWithLabels() async throws {
        let (harness, _) = try await select(Cast.ana)
        let entries = try await harness.submenu("call")
        #expect(entries.map(\.title) == ["Mobile: +1 (555) 010-0101", "Work: +1 555 010 0102 ext. 7"])
        try await harness.perform(try #require(entries.last), row: harness.selectedRow)
        #expect(harness.fakes.workspace.opened == [URL(string: "tel:+15550100102,7")])
        #expect(harness.issues.isEmpty)
    }

    @Test func callsUseTheChosenApp() async throws {
        let (harness, _) = try await select(Cast.bruno)
        harness.context.settings[PeopleSettings.callApp] = "com.example.dialer"
        try await harness.perform("call")
        #expect(harness.fakes.workspace.opened.isEmpty)
        #expect(harness.fakes.workspace.openedWith.map(\.urls) == [[try #require(URL(string: "tel:5550100"))]])
        #expect(harness.fakes.workspace.openedWith.map(\.bundleID) == ["com.example.dialer"])
    }

    @Test func messageEmailAndFaceTimeOpenTheirSchemes() async throws {
        let (harness, _) = try await select(Cast.bruno)
        try await harness.perform("message")
        try await harness.perform("email")
        let video = try await harness.submenu("facetime")
        #expect(video.map(\.title) == ["Mobile: 555 0100", "bruno@example.net"])
        try await harness.perform(video[1], row: harness.selectedRow)
        let audio = try await harness.submenu("facetime-audio")
        try await harness.perform(audio[0], row: harness.selectedRow)
        #expect(
            harness.fakes.workspace.opened.map(\.absoluteString) == [
                "sms:5550100", "mailto:bruno@example.net", "facetime:bruno@example.net", "facetime-audio:5550100",
            ])
    }

    @Test func openingAddressesAndTheCardUseMapsAndContacts() async throws {
        let (harness, _) = try await select(Cast.bakery)
        try await harness.perform("open-address-in-maps")
        try await harness.perform("open-in-contacts")
        #expect(
            harness.fakes.workspace.opened.map(\.absoluteString) == [
                "maps://?address=1%20Market%20Lane%2C%2000002%20Springfield", "addressbook://p-bakery",
            ])
        #expect(try harness.command("search").requires == [.contacts])
    }

    @Test func copyActionsCopyTheValueAndSaySo() async throws {
        let (harness, _) = try await select(Cast.ana)
        try await harness.perform("copy-name")
        try await harness.perform(try #require(try await harness.submenu("copy-phone").first), row: harness.selectedRow)
        try await harness.perform(try #require(try await harness.submenu("copy-email").last), row: harness.selectedRow)
        try await harness.perform("copy-address")
        #expect(
            harness.fakes.pasteboard.copiedTexts == [
                "Ana Lima", "+1 (555) 010-0101", "ana.lima@example.org",
                "12 Sample Street\n00001 Springfield\nST\nUnited States",
            ])
        #expect(
            harness.huds.map(\.title) == [
                "Copied Name", "Copied Phone Number", "Copied Email Address", "Copied Address",
            ])
    }

    /// A number shows in Large Type, Command-L, which closes the panel. Several numbers get a
    /// submenu with their labels.
    @Test func aNumberShowsInLargeType() async throws {
        let (harness, _) = try await select(Cast.bruno)
        let action = try #require(harness.actions().first { $0.id == "large-type-phone" })
        #expect(action.title == "Show Phone Number in Large Type")
        #expect(action.shortcut == .largeType)
        let outcome = try await harness.perform("large-type-phone")
        #expect(outcome.kind == .showLargeType("555 0100"))
        #expect(harness.largeTypeTexts == ["555 0100"])
        #expect(harness.isClosed)

        try harness.select(personID(Cast.ana))
        let entries = try await harness.submenu("large-type-phone")
        #expect(entries.map(\.title) == ["Mobile: +1 (555) 010-0101", "Work: +1 555 010 0102 ext. 7"])
        #expect(harness.issues.isEmpty)
    }

    @Test func theSameNumberWrittenTwoWaysIsOfferedOnce() async throws {
        let person = Person(
            id: "dup", givenName: "Kai",
            phones: [LabeledValue("mobile", "+1 555 010 0101"), LabeledValue("iPhone", "+15550100101")],
            emails: [LabeledValue("", "kai@example.com"), LabeledValue("", " KAI@example.com ")])
        let (harness, _) = try await select(person, among: [person])
        try await harness.perform("call")
        try await harness.perform("email")
        #expect(
            harness.fakes.workspace.opened.map(\.absoluteString) == ["tel:+15550100101", "mailto:kai@example.com"])
    }

    @Test func aNumberThatCannotBeDialledIsOnlyCopied() async throws {
        let person = Person(id: "code", givenName: "Voicemail", phones: [LabeledValue("", "*86")])
        let (harness, _) = try await select(person, among: [person])
        #expect(harness.actionIDs == ["open-in-contacts", "large-type-phone", "copy-name", "copy-phone"])
    }

    @Test(arguments: [
        (PrimaryAction.call, "call"), (.message, "message"), (.email, "email"), (.faceTime, "facetime"),
        (.copyPhone, "copy-phone"), (.copyEmail, "copy-email"), (.openInContacts, "open-in-contacts"),
    ])
    func returnRunsTheChosenAction(_ choice: PrimaryAction, _ expected: String) async throws {
        let (harness, _) = try await select(Cast.ana)
        harness.context.settings[PeopleSettings.primaryAction] = choice
        let actions = harness.actions()
        #expect(actions.first?.id == expected)
        #expect(actions.first?.section == nil)
        #expect(Set(actions.map(\.id)).count == actions.count)
    }

    @Test func aChoiceThePersonCannotHonourFallsBackToTheCard() async throws {
        let (harness, _) = try await select(Cast.lea)
        harness.context.settings[PeopleSettings.primaryAction] = .call
        #expect(harness.actions().first?.id == "open-in-contacts")
        try await harness.performPrimary()
        #expect(harness.fakes.workspace.opened == [URL(string: "addressbook://p-lea")])
    }

    @Test func aFailedOpenSaysWhatFailed() async throws {
        let (harness, _) = try await select(Cast.bruno)
        harness.fakes.workspace.failsToOpen = true
        harness.throwsActionErrors = false
        try await harness.perform("call")
        #expect(harness.visibleToast?.title == Strings.Failures.call)
        #expect(harness.visibleToast?.message == Strings.Failures.openMessage)
    }

    @Test func aRowTheDirectoryNoLongerKnowsStillOpensTheCard() async throws {
        let (harness, _) = await makeHarness()
        let stranger = Row(id: ItemID(PeopleSnapshot.namespace, "gone-1"), title: "Someone")
        #expect(harness.rootActions(for: stranger).map(\.id) == ["open-in-contacts"])
        try await harness.performRoot("open-in-contacts", on: stranger)
        #expect(harness.fakes.workspace.opened == [URL(string: "addressbook://gone-1")])
    }
}
