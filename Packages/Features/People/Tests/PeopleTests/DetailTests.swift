import Foundation
import Kit
import KitTesting
import Testing

@testable import People

@Suite("Detail pane", .timeLimit(.minutes(1)))
@MainActor
struct DetailTests {
    @Test func theDetailShowsWorkNumbersAddressesAndBirthday() async throws {
        let (harness, _) = await makeHarness()
        try await harness.run("search")
        try harness.select(personID(Cast.ana))
        let detail = try #require(try await harness.loadDetail())
        #expect(detail.body == nil)
        #expect(
            detail.metadata == [
                .label("Nickname", value: "Annie"), .label("Company", value: "Example Studio"),
                .label("Job Title", value: "Designer"), .separator,
                .label("Mobile", value: "+1 (555) 010-0101"), .label("Work", value: "+1 555 010 0102 ext. 7"),
                .separator, .label("Home", value: "ana@example.com"), .label("Work", value: "ana.lima@example.org"),
                .separator, .label("Home", value: "12 Sample Street\n00001 Springfield\nST\nUnited States"),
                .separator, .label("Birthday", value: "March 14, 1990"),
            ])
    }

    @Test func aCompanyCardDoesNotRepeatItsName() async throws {
        let (harness, _) = await makeHarness()
        try await harness.run("search")
        try harness.select(personID(Cast.bakery))
        let detail = try #require(try await harness.loadDetail())
        #expect(!detail.metadata.contains(.label("Company", value: "Example Bakery")))
        #expect(detail.metadata.first == .label("Main", value: "555-0100"))
    }

    @Test func phoneticNamesAndUnlabelledValuesRead() async throws {
        let (harness, _) = await makeHarness()
        try await harness.run("search")
        try harness.select(personID(Cast.hiro))
        #expect(try await harness.loadDetail()?.metadata == [.label("Pronunciation", value: "たなか ひろし")])
        try harness.select(personID(Cast.bruno))
        let bruno = try #require(try await harness.loadDetail())
        #expect(bruno.metadata.contains(.label("Email", value: "bruno@example.net")))
    }

    @Test func aBirthdayWithoutAYearShowsDayAndMonth() {
        let locale = Locale(identifier: "en_US")
        #expect(PersonDetail.format(Birthday(day: 2, month: 11, year: nil), locale: locale) == "November 2")
        #expect(PersonDetail.format(Birthday(day: 29, month: 2, year: nil), locale: locale) == "February 29")
        #expect(PersonDetail.format(Birthday(day: 31, month: 2, year: 1990), locale: locale) == nil)
        #expect(
            PersonDetail.format(Birthday(day: 2, month: 11, year: 1985), locale: Locale(identifier: "de_DE"))
                == "2. November 1985")
    }

    @Test func labelsReadAsHeadings() {
        #expect(PersonDetail.labelTitle("mobile", otherwise: "Phone") == "Mobile")
        #expect(PersonDetail.labelTitle("iPhone", otherwise: "Phone") == "iPhone")
        #expect(PersonDetail.labelTitle("", otherwise: "Phone") == "Phone")
        #expect(PersonDetail.labelTitle("  ", otherwise: "Phone") == "Phone")
    }

    @Test func thePhotoBecomesASmallThumbnail() async throws {
        var ana = Cast.ana
        ana.hasPhoto = true
        let (harness, store) = await makeHarness(
            people: [ana], photos: [ana.id: syntheticPNG(width: 1200, height: 800)])
        try await harness.run("search")
        let detail = try #require(try await harness.loadDetail())
        guard case .image(.data(let data)) = detail.body else {
            Issue.record("the detail has no photo")
            return
        }
        let size = try #require(pixelSize(data))
        #expect(size.width == 256 && size.height == 171)
        #expect(store.photoReads == 1)
    }

    @Test func aPersonWithoutAPhotoReadsNoPhoto() async throws {
        let (harness, store) = await makeHarness()
        try await harness.run("search")
        _ = try await harness.loadDetail()
        #expect(store.photoReads == 0)
    }

    @Test func brokenOrHugePhotosAreSkipped() {
        #expect(PhotoThumbnail.make(from: Data()) == nil)
        #expect(PhotoThumbnail.make(from: Data("not an image".utf8)) == nil)
        #expect(PhotoThumbnail.make(from: syntheticPNG(width: 40, height: 30)).flatMap(pixelSize)?.width == 40)
        #expect(
            PhotoThumbnail.make(from: syntheticPNG(width: 300, height: 300), maximumPixels: 64).flatMap(pixelSize)?
                .width == 64)
        // A picture over the pixel limit is never decoded, however small its file.
        let picture = syntheticPNG(width: 40, height: 30)
        #expect(PhotoThumbnail.make(from: picture, maximumSourcePixels: 1_199) == nil)
        #expect(PhotoThumbnail.make(from: picture, maximumSourcePixels: 1_200) != nil)
        #expect(PhotoThumbnail.maximumSourcePixels == 50_000_000)
    }

    @Test func aPhotoThatCannotBeReadLeavesTheRest() async throws {
        var ana = Cast.ana
        ana.hasPhoto = true
        let (harness, store) = await makeHarness(people: [ana], photos: [ana.id: Data("broken".utf8)])
        try await harness.run("search")
        let detail = try #require(try await harness.loadDetail())
        #expect(detail.body == nil)
        #expect(!detail.metadata.isEmpty)
        store.failure = .unreadable
        #expect(try await harness.loadDetail()?.body == nil)
    }
}
