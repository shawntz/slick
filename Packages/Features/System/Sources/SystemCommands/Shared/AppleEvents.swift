import Foundation
import Kit

/// Raw Apple Events, sent off the main thread. `NSAppleScript` is meant for the main thread only, so
/// this builds the events itself.
///
/// Every send checks first, without asking, whether macOS lets this app automate the target. When
/// it does not, the caller gets ``SystemFailure/permissionMissing(_:)`` and the host shows its
/// permission card, so the system prompt only ever follows the user's press of Grant.
nonisolated enum AppleEvents {
    /// A target process addressed by bundle ID, in this login session.
    static func target(bundleID: String) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(bundleIdentifier: bundleID)
    }

    /// Throws ``SystemFailure/permissionMissing(_:)`` when sending to the target would need the
    /// user's consent or was refused. Never shows a prompt. The target must be running.
    static func checkPermission(for target: NSAppleEventDescriptor, bundleID: String) throws {
        guard let address = target.aeDesc else { throw SystemFailure.unavailable }
        let status = AEDeterminePermissionToAutomateTarget(
            address, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
        try check(status, bundleID: bundleID)
    }

    /// An event of the given class and ID to the target.
    static func event(_ eventClass: AEEventClass, _ eventID: AEEventID, to target: NSAppleEventDescriptor)
        -> NSAppleEventDescriptor
    {
        NSAppleEventDescriptor.appleEvent(
            withEventClass: eventClass, eventID: eventID, targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }

    /// Sends without waiting for a reply.
    static func sendWithoutReply(_ event: NSAppleEventDescriptor, bundleID: String) throws {
        do {
            _ = try event.sendEvent(options: [.noReply], timeout: 10)
        } catch {
            try check(OSStatus(truncatingIfNeeded: (error as NSError).code), bundleID: bundleID)
            throw SystemFailure.failed(code: Int32(truncatingIfNeeded: (error as NSError).code))
        }
    }

    /// Sends and waits up to ten seconds for the reply's direct object.
    static func sendForResult(_ event: NSAppleEventDescriptor, bundleID: String) throws -> NSAppleEventDescriptor? {
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: [.waitForReply], timeout: 10)
        } catch {
            try check(OSStatus(truncatingIfNeeded: (error as NSError).code), bundleID: bundleID)
            throw SystemFailure.failed(code: Int32(truncatingIfNeeded: (error as NSError).code))
        }
        if let error = reply.paramDescriptor(forKeyword: keyErrorNumber), error.int32Value != 0 {
            try check(OSStatus(error.int32Value), bundleID: bundleID)
            throw SystemFailure.failed(code: error.int32Value)
        }
        return reply.paramDescriptor(forKeyword: keyDirectObject)
    }

    /// Reads a property: the "get" event of the core suite.
    static func get(_ specifier: NSAppleEventDescriptor, from target: NSAppleEventDescriptor, bundleID: String)
        throws -> NSAppleEventDescriptor?
    {
        let event = event(AEEventClass(kAECoreSuite), AEEventID(kAEGetData), to: target)
        event.setParam(specifier, forKeyword: keyDirectObject)
        return try sendForResult(event, bundleID: bundleID)
    }

    /// Writes a property: the "set" event of the core suite.
    static func set(
        _ specifier: NSAppleEventDescriptor, to value: NSAppleEventDescriptor, in target: NSAppleEventDescriptor,
        bundleID: String
    ) throws {
        let event = event(AEEventClass(kAECoreSuite), AEEventID(kAESetData), to: target)
        event.setParam(specifier, forKeyword: keyDirectObject)
        event.setParam(value, forKeyword: keyAEData)
        _ = try sendForResult(event, bundleID: bundleID)
    }

    /// An object specifier for a property of a container, as AppleScript's `<property> of <container>`.
    /// The application itself is the null descriptor.
    static func property(_ code: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let specifier =
            NSAppleEventDescriptor.record().coerce(toDescriptorType: DescType(typeObjectSpecifier))
            ?? NSAppleEventDescriptor.record()
        specifier.setDescriptor(
            NSAppleEventDescriptor(typeCode: DescType(cProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
        specifier.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        specifier.setDescriptor(
            NSAppleEventDescriptor(enumCode: DescType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        specifier.setDescriptor(
            NSAppleEventDescriptor(typeCode: fourCharCode(code)), forKeyword: AEKeyword(keyAEKeyData))
        return specifier
    }

    /// The four-character code an `sdef` file names, such as "thme".
    static func fourCharCode(_ text: String) -> FourCharCode {
        text.utf8.prefix(4).reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    /// Turns a status into the failure the commands understand. Returns for success.
    private static func check(_ status: OSStatus, bundleID: String) throws {
        switch status {
        case noErr:
            return
        case OSStatus(errAEEventWouldRequireUserConsent), OSStatus(errAEEventNotPermitted):
            throw SystemFailure.permissionMissing(.automation(bundleID: bundleID))
        case OSStatus(procNotFound), OSStatus(connectionInvalid):
            throw SystemFailure.unavailable
        default:
            throw SystemFailure.failed(code: status)
        }
    }
}
