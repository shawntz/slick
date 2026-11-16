import Foundation
import Kit
import KitTesting
import Testing

@testable import People

/// Cases a second review found: numbers whose words leave the digits unclear, and names that show
/// nothing.
@MainActor
@Suite("Hardening", .timeLimit(.minutes(1)))
struct HardeningTests {
    /// Each would have dialled a number the card does not hold: "1800", "55501004663",
    /// "55501001012", "55501007".
    @Test(arguments: [
        "1-800-flowers", "1-800-Flowers", "555-0100-home", "555 010 0101 fax 2", "Mobile5550100",
        "555 0100 ext. 7 mobile", "555 0100 x 12 home",
    ])
    func anUnclearNumberIsNeverDialled(_ input: String) {
        #expect(ContactLinks.call(input) == nil)
        #expect(ContactLinks.message(input) == nil)
        #expect(ContactLinks.faceTime(input, audioOnly: false) == nil)
    }

    @Test(arguments: [
        ("1-800-FLOWERS", "tel:18003569377"),
        ("1 800 FLOWERS", "tel:18003569377"),
        ("555 0100 mobile", "tel:5550100"),
        ("555 0100 (home)", "tel:5550100"),
        ("Tel. 555 0100", "tel:5550100"),
        ("Mobile: +1 555 010 0101", "tel:+15550100101"),
        ("+1 555 010 0102 ext. 7", "tel:+15550100102,7"),
    ])
    func clearNumbersStillDial(_ input: String, _ expected: String) {
        #expect(ContactLinks.call(input)?.absoluteString == expected)
    }

    @Test func aPersonWithOnlyAnUnclearNumberCanCopyItButNotCallIt() async throws {
        let person = Person(id: "p-shop", givenName: "Flora", phones: [LabeledValue("work", "1-800-flowers")])
        let (harness, _) = await makeHarness(people: [person])
        try await harness.run("search")
        try harness.select(title: "Flora")
        #expect(harness.actionIDs == ["open-in-contacts", "large-type-phone", "copy-name", "copy-phone"])
        try await harness.perform("copy-phone")
        #expect(harness.fakes.pasteboard.copiedTexts == ["1-800-flowers"])
        #expect(harness.fakes.workspace.opened.isEmpty)
    }

    @Test func namesMadeOfInvisibleCharactersFallBackToWhatShows() {
        let zeroWidth = Person(
            id: "p-zw", givenName: "\u{200B}", familyName: "\u{2060}\u{FEFF}", nickname: "\u{200D}",
            emails: [LabeledValue("", "someone@example.com")])
        #expect(PersonName.title(of: zeroWidth) == "someone@example.com")
        let nothing = Person(id: "p-none", givenName: "\u{200B}\u{200B}", formattedName: "\u{200B} \u{200C}")
        #expect(PersonName.title(of: nothing) == "No Name")
        let company = Person(id: "p-co", givenName: "\u{200E}", organization: "Example Bakery")
        #expect(PersonName.title(of: company) == "Example Bakery")
    }

    @Test func aListOfInvisibleNamesHasNoInvisibleRow() async throws {
        let people = [
            Person(id: "p-1", givenName: "\u{200B}"),
            Person(id: "p-2", familyName: "\u{2060}", phones: [LabeledValue("", "555 0100")]),
            Person(id: "p-3", givenName: "\u{FEFF}", organization: "Example Studio"),
        ]
        let (harness, _) = await makeHarness(people: people)
        try await harness.run("search")
        #expect(Set(harness.titles) == ["No Name", "555 0100", "Example Studio"])
        #expect(harness.issues.isEmpty)
    }

    @Test func thePrivacyNoteNamesWhatRootSearchLearns() {
        let note = Strings.Settings.privacyNote
        #expect(note.contains("sends nothing over the network"))
        #expect(note.contains("Root search learns which person you pick"))
        #expect(!note.contains("nothing about them to disk"))
    }
}
