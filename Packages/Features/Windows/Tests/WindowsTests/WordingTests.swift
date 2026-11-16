import Foundation
import Kit
import KitTesting
import Testing

@testable import Windows

/// Titles take title case without a full stop. These pin the titles that broke the rule.
@Suite("Wording", .timeLimit(.minutes(1)))
struct WordingTests {
    @Test func noticeAndQuestionTitlesTakeTitleCase() {
        #expect(Strings.needsAccessTitle == "Switch Windows Needs Accessibility")
        #expect(Strings.closeQuestion(title: nil, app: "Example Player") == "Close This Example Player Window?")
        #expect(Strings.closeQuestion(title: "", app: nil) == "Close This Window?")
    }
}
