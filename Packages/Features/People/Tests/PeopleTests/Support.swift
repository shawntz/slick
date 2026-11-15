import Foundation
import ImageIO
import Kit
import KitTesting
import Testing
import UniformTypeIdentifiers

@testable import People

/// Invented people. Numbers use the 555-01xx range kept for fiction and addresses use example.com.
nonisolated enum Cast {
    static let ana = Person(
        id: "p-ana", givenName: "Ana", familyName: "Lima", nickname: "Annie", organization: "Example Studio",
        jobTitle: "Designer",
        phones: [LabeledValue("mobile", "+1 (555) 010-0101"), LabeledValue("work", "+1 555 010 0102 ext. 7")],
        emails: [LabeledValue("home", "ana@example.com"), LabeledValue("work", "ana.lima@example.org")],
        addresses: [
            PostalAddress(
                label: "home", street: "12 Sample Street", city: "Springfield", state: "ST", postalCode: "00001",
                country: "United States")
        ],
        birthday: Birthday(day: 14, month: 3, year: 1990))

    static let bruno = Person(
        id: "p-bruno", givenName: "Bruno", familyName: "Costa", phones: [LabeledValue("mobile", "555 0100")],
        emails: [LabeledValue("", "bruno@example.net")])

    static let daria = Person(
        id: "p-daria", givenName: "Дарья", familyName: "Иванова", emails: [LabeledValue("work", "daria@example.com")])

    static let hiro = Person(
        id: "p-hiro", givenName: "宏", familyName: "田中", phoneticGivenName: "ひろし", phoneticFamilyName: "たなか")

    static let wei = Person(id: "p-wei", givenName: "伟", familyName: "王")

    static let lea = Person(id: "p-lea", givenName: "Léa", familyName: "Müller")

    static let bakery = Person(
        id: "p-bakery", kind: .organization, organization: "Example Bakery",
        phones: [LabeledValue("main", "555-0100")],
        addresses: [PostalAddress(label: "work", street: "1 Market Lane", city: "Springfield", postalCode: "00002")])

    /// A card with no name and no kind set, only a company, as an import often leaves it.
    static let workshop = Person(id: "p-workshop", organization: "Example Workshop")

    static let all = [ana, bruno, daria, hiro, wei, lea, bakery, workshop]
}

/// A harness over the fakes with an in-memory store, as the app would run the feature.
@MainActor
func makeHarness(
    people: [Person] = Cast.all, photos: [String: Data] = [:], access: PermissionStatus = .granted,
    fakes: FakeServices = FakeServices()
) async -> (harness: FeatureHarness<PeopleFeature>, store: InMemoryPeople) {
    let store = InMemoryPeople(people: people, photos: photos)
    fakes.override(PeopleServiceKey.self, with: store)
    fakes.permissions.set(.contacts, to: access)
    let harness = FeatureHarness(PeopleFeature.self, fakes: fakes)
    await harness.activate()
    return (harness, store)
}

/// The row ID of a person.
func personID(_ person: Person) -> ItemID {
    ItemID(PeopleSnapshot.namespace, person.id)
}

/// A PNG of one color, made in memory.
func syntheticPNG(width: Int, height: Int) -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    guard
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return Data() }
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else { return Data() }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
    else { return Data() }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

/// The pixel size of encoded image data.
func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (width, height)
}

extension FeatureHarness {
    /// The titles of the visible rows, in order.
    var titles: [String] { rows.map(\.title) }

    /// The IDs of the actions the panel shows for the selected row.
    var actionIDs: [String] { actions().map(\.id) }
}
