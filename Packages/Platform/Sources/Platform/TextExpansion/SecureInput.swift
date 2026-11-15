import AppKit
import Carbon
import Foundation
import IOKit

/// Whether an app holds secure input, which hides keystrokes from every keyboard tap.
nonisolated public struct SecureInputState: Hashable, Sendable {
    public var isOn: Bool
    /// The name of the app that holds it, when known.
    public var owner: String?

    public init(isOn: Bool, owner: String? = nil) {
        self.isOn = isOn
        self.owner = owner
    }

    public static let off = SecureInputState(isOn: false)
}

/// Reads the secure input state. ``SystemSecureInput`` is the live one.
nonisolated public protocol SecureInputReader: Sendable {
    func current() -> SecureInputState
}

/// The live reader: `IsSecureEventInputEnabled`, and the owner's process ID from the IORegistry's
/// console users. Read-only; nothing here prompts.
nonisolated public struct SystemSecureInput: SecureInputReader {
    public init() {}

    public func current() -> SecureInputState {
        guard IsSecureEventInputEnabled() else { return .off }
        return SecureInputState(isOn: true, owner: Self.ownerName())
    }

    /// The name of the app whose process the window server lists as holding secure input.
    static func ownerName() -> String? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard
            let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [[String: Any]]
        else { return nil }
        for user in users {
            if let processID = (user["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value, processID > 0 {
                return NSRunningApplication(processIdentifier: processID)?.localizedName
            }
        }
        return nil
    }
}

/// A reader that always reports secure input off, for run environments other than `live`.
nonisolated public struct NoSecureInput: SecureInputReader {
    public init() {}

    public func current() -> SecureInputState { .off }
}
