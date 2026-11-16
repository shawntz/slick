import Foundation
import Kit
import Testing

@testable import Platform

/// Host shows a thrown error's description as a failure toast's title and its failure reason as the
/// message. Titles take title case without a full stop; messages are sentences.
@Suite(.timeLimit(.minutes(1))) struct ErrorWordingTests {
    @Test func workspaceErrorsHaveATitleAndASentence() {
        let missing = WorkspaceError.applicationNotFound("com.example.missing")
        #expect(missing.errorDescription == "App Not Installed")
        #expect(missing.failureReason == "No app with the identifier com.example.missing is installed.")
        let one = WorkspaceError.trashFailed([URL(filePath: "/synthetic/report.pdf")], moved: [])
        #expect(one.errorDescription == "Could Not Move to the Trash")
        #expect(one.failureReason == "report.pdf could not be moved to the Trash.")
        let two = WorkspaceError.trashFailed([URL(filePath: "/synthetic/a"), URL(filePath: "/synthetic/b")], moved: [])
        #expect(two.failureReason == "2 items could not be moved to the Trash.")
    }

    @Test func keychainErrorsHaveATitleAndASentence() {
        #expect(KeychainError.notText.errorDescription == "Stored Secret Is Not Text")
        #expect(KeychainError.unexpectedResult.errorDescription == "Unexpected Keychain Result")
        #expect(KeychainError.status(-25_300).errorDescription == "Keychain Error -25300")
        for error in [KeychainError.notText, .unexpectedResult, .status(-25_300)] {
            #expect(error.errorDescription?.hasSuffix(".") == false)
            #expect(error.failureReason?.hasSuffix(".") == true)
        }
    }
}
