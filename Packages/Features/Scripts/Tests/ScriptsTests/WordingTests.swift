import Foundation
import Kit
import KitTesting
import Testing

@testable import Scripts

/// Titles take title case without a full stop; everything else is a sentence. These pin the
/// titles that broke the rule.
@Suite("Wording", .timeLimit(.minutes(1)))
struct WordingTests {
    @Test func statusesAreTitlesWithTheirDetailInTheMessage() {
        #expect(Strings.problemsStatus(1) == "1 Script Has a Problem")
        #expect(Strings.problemsStatus(3) == "3 Scripts Have Problems")
        #expect(Strings.offStatus(1) == "1 Script Is Off")
        #expect(Strings.offStatus(2) == "2 Scripts Are Off")
        #expect(Strings.missingFolderStatus == "Script Folder Not Found")
        #expect(Strings.missingFolderMessage("~/Scripts").hasSuffix("."))
        #expect(Strings.offStatusMessage.hasSuffix("."))
    }

    @Test func questionsAndFallbacksTakeTitleCase() {
        #expect(Strings.turnOnFolderQuestion("Tools") == "Run Scripts from Tools?")
        #expect(
            Strings.runFallback("Search Issues", text: "login bug") == "Search Issues with \u{201C}login bug\u{201D}")
    }
}
