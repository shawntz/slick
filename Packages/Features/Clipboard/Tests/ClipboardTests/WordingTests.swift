import Foundation
import Kit
import KitTesting
import Testing

@testable import Clipboard

/// Titles take title case without a full stop; everything else is a sentence. These pin the
/// titles that broke the rule: notices, statuses and questions.
@Suite("Wording", .timeLimit(.minutes(1)))
struct WordingTests {
    @Test func noticeAndStatusTitlesTakeTitleCase() {
        #expect(Strings.List.pausedTitle == "Recording Is Paused")
        #expect(Strings.List.notAllowedTitle == "Copies Are Not Being Recorded")
        #expect(Strings.List.damagedTitle == "Your Earlier Clipboard History Could Not Be Read")
        #expect(Strings.Status.needsAccess == "Clipboard History Cannot See What You Copy")
        #expect(Strings.Status.paused == "Recording Is Paused")
    }

    @Test func questionsTakeTitleCase() {
        #expect(Strings.Commands.clearHistoryConfirmation.title == "Delete Your Clipboard History?")
        #expect(Strings.Commands.clearRecentConfirmation.title == "Delete Recent Clipboard History?")
        #expect(Strings.Actions.deleteConfirmation.title == "Delete This Item?")
        #expect(Strings.Actions.deleteAllConfirmation.title == "Delete All Clipboard History?")
        #expect(Strings.Actions.openManyConfirmation(3).title == "Open 3 Files?")
    }
}
