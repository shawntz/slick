import Foundation
import ServiceManagement
import Testing

@testable import Platform

/// The login item switch over a fake registration. Nothing is registered with macOS.
@Suite(.timeLimit(.minutes(1))) @MainActor struct LoginItemTests {
    @Test func turningOnRegistersAndTurningOffUnregisters() throws {
        let service = FakeLoginItemService(status: .notRegistered)
        let item = MainAppLoginItem(service: service)
        #expect(!item.isEnabled)
        try item.setEnabled(true)
        #expect(item.isEnabled)
        try item.setEnabled(true)
        try item.setEnabled(false)
        try item.setEnabled(false)
        #expect(service.calls == ["register", "unregister"])
    }

    /// Found in review: after the user turned the app off in Login Items, the switch flipped back
    /// without a word.
    @Test func aRegistrationThatNeedsApprovalOpensLoginItemsAndSaysSo() {
        let service = FakeLoginItemService(status: .notRegistered)
        service.statusAfterRegister = .requiresApproval
        let item = MainAppLoginItem(service: service)
        #expect(throws: LoginItemError.needsApproval) { try item.setEnabled(true) }
        #expect(service.calls == ["register", "open"])
        #expect(item.needsApproval)
        // Asked again, it does not register twice; it opens the pane again.
        #expect(throws: LoginItemError.needsApproval) { try item.setEnabled(true) }
        #expect(service.calls == ["register", "open", "open"])
        #expect(LoginItemError.needsApproval.errorDescription?.hasSuffix(".") == false)
        #expect(LoginItemError.needsApproval.failureReason?.hasSuffix(".") == true)
    }
}

@MainActor final class FakeLoginItemService: LoginItemService {
    var status: SMAppService.Status
    var statusAfterRegister: SMAppService.Status = .enabled
    var calls: [String] = []

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        calls.append("register")
        status = statusAfterRegister
    }

    func unregister() throws {
        calls.append("unregister")
        status = .notRegistered
    }

    func openLoginItemsSettings() {
        calls.append("open")
    }
}
