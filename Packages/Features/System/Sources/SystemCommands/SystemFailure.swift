import Kit

/// Why a system call did not happen. The feature's services throw it, and the commands turn it into
/// words from ``Strings`` or into the host's permission card.
nonisolated enum SystemFailure: Error, Hashable, Sendable {
    /// This Mac or this version of macOS has no way to do it, such as an output device without a
    /// volume control.
    case unavailable
    /// macOS refuses until the user grants this permission.
    case permissionMissing(Permission)
    /// The thing to act on is gone, such as a process that has already quit.
    case notFound
    /// The feature never does this to the thing, such as quitting a process the login session
    /// depends on.
    case protected
    /// The system returned this error code.
    case failed(code: Int32)
}

/// What a command says when its system call fails.
nonisolated struct FailureWords: Sendable {
    /// The title when the call failed with an error code.
    var failed: String
    /// The title when this Mac cannot do it at all.
    var unavailable: String
    /// The title when the thing to act on is gone. Defaults to ``unavailable``.
    var notFound: String?
}

extension SystemFailure {
    /// Runs a command's body and turns a ``SystemFailure`` into what the host shows: the permission
    /// card for a missing permission, otherwise a failure toast or HUD in the command's own words.
    @MainActor static func handle(
        _ words: FailureWords, _ body: () async throws -> ActionOutcome
    ) async throws -> ActionOutcome {
        do {
            return try await body()
        } catch let failure as SystemFailure {
            switch failure {
            case .permissionMissing(let permission):
                return .needsPermission(permission)
            case .unavailable:
                throw ActionFailure(words.unavailable)
            case .notFound:
                throw ActionFailure(words.notFound ?? words.unavailable)
            case .protected:
                throw ActionFailure(words.failed, message: Strings.protectedMessage)
            case .failed(let code):
                throw ActionFailure(words.failed, message: Strings.errorCode(code))
            }
        }
    }
}
