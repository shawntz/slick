import Foundation
import Testing

@testable import People

@Suite("URL builders", .timeLimit(.minutes(1)))
struct LinkTests {
    @Test(arguments: [
        ("+1 (555) 010-0101", "tel:+15550100101"),
        ("555 0100", "tel:5550100"),
        ("555.010.0101", "tel:5550100101"),
        ("+44 7700 900123", "tel:+447700900123"),
        ("  +81 90-0000-0000  ", "tel:+819000000000"),
        ("0049 30 0000000", "tel:0049300000000"),
        ("+1\u{00A0}555\u{00A0}010\u{00A0}0101", "tel:+15550100101"),
        ("＋１ ５５５ ０１０ ０１０１", "tel:+15550100101"),
        ("+٩٧١ ٥٥٥ ٠١٠٠", "tel:+9715550100"),
        ("1-800-FLOWERS", "tel:18003569377"),
        ("555 0100 mobile", "tel:5550100"),
    ])
    func callTakesNumbersAsPeopleWriteThem(_ input: String, _ expected: String) {
        #expect(ContactLinks.call(input)?.absoluteString == expected)
    }

    @Test(arguments: [
        ("+1 555 010 0102 ext. 7", "tel:+15550100102,7"),
        ("+1 555 010 0102 ext 77", "tel:+15550100102,77"),
        ("+1 555 010 0102 Extension 123", "tel:+15550100102,123"),
        ("+1 555 010 0102 x12", "tel:+15550100102,12"),
        ("+1 555 010 0102 X 12", "tel:+15550100102,12"),
        ("555-010-0102 #34", "tel:5550100102,34"),
        ("555-010-0102,34", "tel:5550100102,34"),
        ("555-010-0102;34", "tel:5550100102,34"),
        ("555-010-0102 ext: 5", "tel:5550100102,5"),
    ])
    func callDialsTheExtensionAfterAPause(_ input: String, _ expected: String) {
        #expect(ContactLinks.call(input)?.absoluteString == expected)
    }

    @Test(arguments: ["", "  ", "mobile", "12", "*31#", "555*0100", "+1 555 +0100", "phone me"])
    func callRefusesWhatIsNotADialableNumber(_ input: String) {
        #expect(ContactLinks.call(input) == nil)
        #expect(ContactLinks.message(input) == nil)
    }

    @Test func aTooLongNumberIsRefused() {
        #expect(ContactLinks.call(String(repeating: "5", count: 21)) == nil)
        #expect(ContactLinks.call(String(repeating: "5 ", count: 200)) == nil)
    }

    @Test func aWordEndingInXIsNotAnExtension() {
        // "fax" ends in x; the digits after it are part of the note, not an extension marker.
        let dial = ContactLinks.dialString("555 010 0101 fax 2")
        #expect(dial?.extension == nil)
    }

    @Test func messageLeavesTheExtensionOut() {
        #expect(ContactLinks.message("+1 555 010 0102 ext. 7")?.absoluteString == "sms:+15550100102")
        #expect(ContactLinks.message("(555) 010-0101")?.absoluteString == "sms:5550100101")
    }

    @Test func faceTimeTakesNumbersAndEmailAddresses() {
        #expect(ContactLinks.faceTime("+1 (555) 010-0101", audioOnly: false)?.absoluteString == "facetime:+15550100101")
        #expect(
            ContactLinks.faceTime("+1 (555) 010-0101", audioOnly: true)?.absoluteString
                == "facetime-audio:+15550100101")
        #expect(
            ContactLinks.faceTime(" ana@example.com ", audioOnly: false)?.absoluteString == "facetime:ana@example.com")
        #expect(
            ContactLinks.faceTime("ana@example.com", audioOnly: true)?.absoluteString
                == "facetime-audio:ana@example.com")
        #expect(ContactLinks.faceTime("not a handle", audioOnly: false) == nil)
    }

    @Test func emailEncodesWhatMailtoCannotCarry() {
        #expect(ContactLinks.email("ana@example.com")?.absoluteString == "mailto:ana@example.com")
        #expect(ContactLinks.email("  ana+news@example.com\n")?.absoluteString == "mailto:ana+news@example.com")
        #expect(ContactLinks.email("a&b@example.com")?.absoluteString == "mailto:a%26b@example.com")
        #expect(ContactLinks.email("a?b=c@example.com")?.absoluteString == "mailto:a%3Fb%3Dc@example.com")
        #expect(ContactLinks.email("ana@exämple.com")?.absoluteString == "mailto:ana@ex%C3%A4mple.com")
    }

    @Test(arguments: ["", "ana", "@example.com", "ana@", "a b@example.com", "a@b@example.com", "ana@\u{0}x.com"])
    func emailRefusesWhatIsNotAnAddress(_ input: String) {
        #expect(ContactLinks.email(input) == nil)
    }

    @Test func mapsEncodesEveryCharacterButTheSafeOnes() throws {
        let address = PostalAddress(
            street: "12 Sample Street\nFlat 3+4", city: "Springfield", state: "ST", postalCode: "00001",
            country: "United States")
        let url = try #require(ContactLinks.maps(address))
        #expect(
            url.absoluteString
                == "maps://?address=12%20Sample%20Street%2C%20Flat%203%2B4%2C%2000001%20Springfield%2C%20ST%2C%20United%20States"
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(
            components.queryItems?.first?.value
                == "12 Sample Street, Flat 3+4, 00001 Springfield, ST, United States")
    }

    @Test func mapsKeepsAmpersandsAndOtherScriptsInTheAddress() throws {
        let url = try #require(ContactLinks.maps(PostalAddress(street: "Rue A&B 1", city: "Zürich")))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.count == 1)
        #expect(components.queryItems?.first?.value == "Rue A&B 1, Zürich")
    }

    @Test func mapsUsesTheSystemFormatWhenGiven() throws {
        let address = PostalAddress(street: "ignored", formatted: "1 Example Road\n\nSpringfield  ")
        #expect(address.lines == ["1 Example Road", "Springfield"])
        let url = try #require(ContactLinks.maps(address))
        #expect(url.absoluteString == "maps://?address=1%20Example%20Road%2C%20Springfield")
    }

    @Test func mapsRefusesAnEmptyAddress() {
        #expect(ContactLinks.maps(PostalAddress()) == nil)
        #expect(ContactLinks.maps(PostalAddress(street: "  \n ")) == nil)
    }

    @Test func contactsCardKeepsTheStoreIdentifier() {
        #expect(
            ContactLinks.contactsCard("410FE041-5C4E-48DA-B4DE-04C15EA3DBAC:ABPerson")?.absoluteString
                == "addressbook://410FE041-5C4E-48DA-B4DE-04C15EA3DBAC:ABPerson")
        #expect(ContactLinks.contactsCard("a b/c")?.absoluteString == "addressbook://a%20b%2Fc")
        #expect(ContactLinks.contactsCard("") == nil)
    }

    @Test func twoWaysOfWritingANumberCompareEqual() {
        #expect(ContactLinks.comparableDigits("+1 (555) 010-0101") == ContactLinks.comparableDigits("+15550100101"))
        #expect(ContactLinks.comparableDigits("555 0100 x1") != ContactLinks.comparableDigits("555 0100 x2"))
    }
}
