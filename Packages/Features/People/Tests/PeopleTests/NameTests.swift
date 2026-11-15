import Foundation
import Testing

@testable import People

@Suite("Names", .timeLimit(.minutes(1)))
struct NameTests {
    @Test func aPersonIsTitledByTheirFullName() {
        let person = Person(
            id: "1", namePrefix: "Dr.", givenName: "Ana", middleName: "Maria", familyName: "Lima", nameSuffix: "Jr.")
        #expect(PersonName.title(of: person) == "Dr. Ana Maria Lima Jr.")
        #expect(PersonName.order(of: person) == .givenFirst)
    }

    @Test func eastAsianNamesReadFamilyNameFirst() {
        #expect(PersonName.title(of: Cast.hiro) == "田中 宏")
        #expect(PersonName.title(of: Cast.wei) == "王 伟")
        #expect(PersonName.order(of: Person(id: "k", givenName: "민준", familyName: "김")) == .familyFirst)
        #expect(PersonName.phoneticName(of: Cast.hiro) == "たなか ひろし")
    }

    @Test func theSystemsOrderAndFormatWin() {
        var person = Person(id: "1", givenName: "Ana", familyName: "Lima")
        person.nameOrder = .familyFirst
        #expect(PersonName.title(of: person) == "Lima Ana")
        person.formattedName = "Lima, Ana"
        #expect(PersonName.title(of: person) == "Lima, Ana")
        person.formattedName = "  "
        #expect(PersonName.title(of: person) == "Lima Ana")
    }

    @Test func aCardWithoutANameFallsBackInOrder() {
        #expect(PersonName.title(of: Person(id: "1", nickname: "Ace", organization: "Example Co")) == "Ace")
        #expect(PersonName.title(of: Cast.workshop) == "Example Workshop")
        #expect(PersonName.titleIsOrganization(Cast.workshop))
        #expect(PersonName.title(of: Person(id: "1", emails: [LabeledValue("", "x@example.com")])) == "x@example.com")
        #expect(PersonName.title(of: Person(id: "1", phones: [LabeledValue("", "555 0100")])) == "555 0100")
        #expect(PersonName.title(of: Person(id: "1")) == Strings.Rows.noName)
    }

    @Test func aCompanyCardIsTitledByItsCompanyEvenWithAPersonsName() {
        let card = Person(
            id: "1", kind: .organization, givenName: "Ana", familyName: "Lima", organization: "Example Co")
        #expect(PersonName.title(of: card) == "Example Co")
        #expect(PersonName.titleIsOrganization(card))
        #expect(PersonName.rootKeywords(of: card, title: "Example Co").contains("Ana Lima"))
    }

    @Test func subtitlesTellPeopleApart() {
        #expect(PersonName.subtitle(of: Cast.ana, title: "Ana Lima") == "Designer, Example Studio")
        #expect(PersonName.subtitle(of: Cast.bruno, title: "Bruno Costa") == "bruno@example.net")
        #expect(PersonName.subtitle(of: Cast.bakery, title: "Example Bakery") == "555-0100")
        #expect(PersonName.subtitle(of: Cast.workshop, title: "Example Workshop") == nil)
        let onlyEmail = Person(id: "1", emails: [LabeledValue("", "x@example.com")])
        #expect(PersonName.subtitle(of: onlyEmail, title: "x@example.com") == nil)
    }

    @Test func rootKeywordsHoldNamesOnly() {
        let words = PersonName.rootKeywords(of: Cast.ana, title: "Ana Lima")
        #expect(words.contains("Annie"))
        #expect(words.contains("Example Studio"))
        #expect(!words.contains { $0.contains("@") || $0.contains("555") || $0.contains("Sample Street") })
    }

    @Test func listKeywordsAddContactDetailsAndBareDigits() {
        let words = PersonName.listKeywords(of: Cast.ana, title: "Ana Lima")
        #expect(words.contains("ana@example.com"))
        #expect(words.contains("+1 (555) 010-0101"))
        #expect(words.contains("15550100101"))
        #expect(words.contains("Designer"))
    }

    @Test func otherScriptsGetALatinSpelling() {
        #expect(PersonName.rootKeywords(of: Cast.daria, title: "Дарья Иванова").contains("Darʹâ Ivanova"))
        #expect(PersonName.rootKeywords(of: Cast.hiro, title: "田中 宏").contains("tanaka hiroshi"))
        #expect(PersonName.rootKeywords(of: Cast.wei, title: "王 伟").contains("wáng wěi"))
        #expect(PersonName.latinSpelling(of: "Léa Müller") == nil)
        #expect(PersonName.latinSpelling(of: "Ana") == nil)
    }

    @Test func namesStayOnOneLine() {
        #expect(PersonName.oneLine("  Ana\n\tLima \u{0} Jr. ") == "Ana Lima Jr.")
        let person = Person(id: "1", givenName: "Ana\nMaria", familyName: "Lima\r\n")
        #expect(PersonName.title(of: person) == "Ana Maria Lima")
    }

    @Test func sortingIgnoresCaseAndAccents() {
        #expect(PersonName.sortKey("Émile") == PersonName.sortKey("emile"))
        #expect(PersonName.sortKey("Léa") < PersonName.sortKey("Lima"))
    }
}
