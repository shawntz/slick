import Foundation
import Kit
import KitTesting
import Testing

@testable import Schedule

/// The Length menu's options are menu items, so they take title case.
@Suite("Wording", .timeLimit(.minutes(1)))
struct WordingTests {
    @Test func lengthOptionsTakeTitleCase() {
        #expect(
            [30, 60, 90, 120, 150].map(Strings.Forms.minutes) == [
                "30 Minutes", "1 Hour", "1.5 Hours", "2 Hours", "2 h 30 min",
            ])
        #expect(Strings.Forms.allDay == "All Day")
    }
}
