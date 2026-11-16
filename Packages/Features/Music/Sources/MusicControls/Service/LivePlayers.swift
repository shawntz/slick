import AppKit
import Foundation

/// The real Music and Spotify, through raw Apple Events. Used only when the app runs for a person.
///
/// - Which players run: `NSRunningApplication.runningApplications(withBundleIdentifier:)`. It
///   needs no permission and asks no player anything.
/// - Every event goes to the running process by its process ID, never by bundle ID. An event
///   addressed by bundle ID can start an app that is not running, and one addressed by process ID
///   cannot: when the player has quit, the send fails and nothing starts.
/// - Before every event, `AEDeterminePermissionToAutomateTarget` checks without asking whether
///   this app may control the player. When macOS would ask, nothing is sent and the caller gets
///   ``PlayerFailure/permissionNeeded(_:)``, so the host shows its card and the system prompt
///   follows only the user's press of Grant. Every send also carries
///   `kAEDoNotPromptForUserConsent`, so even a send that slips past the check cannot prompt.
/// - `NSAppleScript` is meant for the main thread, so this builds the events itself, off it.
/// - The four-character codes are in ``ScriptingTerms``, one place per player.
nonisolated final class LivePlayers: PlayerService {
    /// How long a player has to answer one event, in seconds.
    static let timeout: TimeInterval = 3

    init() {}

    @concurrent func runningPlayers() async -> [Player] {
        Player.allCases.filter { Self.processID(of: $0) != nil }
    }

    @concurrent func status(of player: Player) async throws -> NowPlaying {
        let target = try Self.target(for: player)
        let terms = player.terms
        let application = NSAppleEventDescriptor.null()
        let stateCode = try Self.get(terms.playerState, of: application, from: target, player: player)?.enumCodeValue
        let state = stateCode.map { terms.state(forEnumerator: FourCC.text($0)) } ?? .stopped
        guard state != .stopped else { return NowPlaying(player: player, state: .stopped) }

        let current = Self.property(terms.currentTrack, of: application)
        let title: String
        do {
            title = try Self.get(terms.trackName, of: current, from: target, player: player)?.stringValue ?? ""
        } catch PlayerFailure.failed(_, let code) where code == Int32(errAENoSuchObject) {
            // A player can be paused with no current track, as after its queue was cleared.
            return NowPlaying(player: player, state: state)
        }
        // The other facts are extras: a track without them still shows by its title.
        let artist = try Self.extra(terms.trackArtist, of: current, from: target, player: player)?.stringValue
        let album = try Self.extra(terms.trackAlbum, of: current, from: target, player: player)?.stringValue
        let length = try Self.extra(terms.trackDuration, of: current, from: target, player: player).flatMap(
            Self.double)
        let position = try Self.extra(terms.playerPosition, of: application, from: target, player: player).flatMap(
            Self.double)
        let track = Track(
            title: title, artist: artist ?? "", album: album ?? "", duration: length.map { $0 * terms.durationUnit })
        return NowPlaying(player: player, state: state, track: track, position: position)
    }

    /// Reads a property the status can do without. Nil when the player has no such value, such as
    /// a stream without a length. A player that stops answering, quits or loses its permission
    /// still ends the read, so one hung player costs one timeout, not one per property.
    private static func extra(
        _ code: String, of container: NSAppleEventDescriptor, from target: NSAppleEventDescriptor, player: Player
    ) throws -> NSAppleEventDescriptor? {
        do {
            return try get(code, of: container, from: target, player: player)
        } catch PlayerFailure.failed {
            return nil
        }
    }

    @concurrent func send(_ transport: Transport, to player: Player) async throws {
        let target = try Self.target(for: player)
        let code = player.terms.event(for: transport)
        let event = Self.event(code, to: target)
        _ = try Self.send(event, player: player)
    }

    // MARK: - Finding the player

    /// The process ID of the running player, or nil when it does not run. Reads the list of
    /// running apps, which needs no permission and sends nothing.
    static func processID(of player: Player) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID)
            .first { !$0.isTerminated && $0.processIdentifier > 0 }?.processIdentifier
    }

    /// The running player as an event target, once it is known to run and to take events from this
    /// app. Never prompts and never starts the player.
    private static func target(for player: Player) throws -> NSAppleEventDescriptor {
        guard let pid = processID(of: player) else { throw PlayerFailure.notRunning(player) }
        try checkPermission(for: player)
        return NSAppleEventDescriptor(processIdentifier: pid)
    }

    /// Throws when sending to the player would need the user's consent or was refused. Never shows
    /// a prompt: the last argument says not to ask. The check is addressed by bundle ID, as the
    /// permission is, and answers procNotFound rather than starting a player that is not running.
    private static func checkPermission(for player: Player) throws {
        let address = NSAppleEventDescriptor(bundleIdentifier: player.bundleID)
        // The pointer belongs to the descriptor, so the descriptor must outlive the call.
        let status = withExtendedLifetime(address) { () -> OSStatus in
            guard let desc = address.aeDesc else { return OSStatus(errAEWrongDataType) }
            return AEDeterminePermissionToAutomateTarget(
                desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
        }
        try check(status, player: player)
    }

    // MARK: - Events

    /// An event of the given class and ID to the target.
    private static func event(_ code: EventCode, to target: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        event(FourCC.code(code.eventClass), FourCC.code(code.eventID), to: target)
    }

    private static func event(_ eventClass: AEEventClass, _ eventID: AEEventID, to target: NSAppleEventDescriptor)
        -> NSAppleEventDescriptor
    {
        NSAppleEventDescriptor.appleEvent(
            withEventClass: eventClass, eventID: eventID, targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }

    /// Reads a property of a container with the core suite's "get" event, core/getd.
    private static func get(
        _ code: String, of container: NSAppleEventDescriptor, from target: NSAppleEventDescriptor, player: Player
    ) throws -> NSAppleEventDescriptor? {
        let event = event(AEEventClass(kAECoreSuite), AEEventID(kAEGetData), to: target)
        event.setParam(property(code, of: container), forKeyword: keyDirectObject)
        return try send(event, player: player)
    }

    /// The options of every send: wait for the reply, never let the player interact with the
    /// user, and never prompt for consent.
    static let sendOptions: NSAppleEventDescriptor.SendOptions = [
        .waitForReply, .neverInteract, NSAppleEventDescriptor.SendOptions(rawValue: UInt(kAEDoNotPromptForUserConsent)),
    ]

    /// Sends, waits up to ``timeout`` for the reply, and returns its direct object.
    private static func send(_ event: NSAppleEventDescriptor, player: Player) throws -> NSAppleEventDescriptor? {
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: sendOptions, timeout: timeout)
        } catch {
            let code = OSStatus(truncatingIfNeeded: (error as NSError).code)
            try check(code, player: player)
            throw PlayerFailure.failed(player, code: code)
        }
        if let error = reply.paramDescriptor(forKeyword: keyErrorNumber), error.int32Value != 0 {
            try check(OSStatus(error.int32Value), player: player)
            throw PlayerFailure.failed(player, code: error.int32Value)
        }
        return reply.paramDescriptor(forKeyword: keyDirectObject)
    }

    /// Turns a status into a ``PlayerFailure``. Returns for success.
    private static func check(_ status: OSStatus, player: Player) throws {
        switch status {
        case noErr:
            return
        case OSStatus(errAEEventWouldRequireUserConsent):
            throw PlayerFailure.permissionNeeded(player)
        case OSStatus(errAEEventNotPermitted):
            throw PlayerFailure.permissionDenied(player)
        case OSStatus(procNotFound), OSStatus(connectionInvalid):
            throw PlayerFailure.notRunning(player)
        case OSStatus(errAETimeout):
            throw PlayerFailure.timedOut(player)
        default:
            throw PlayerFailure.failed(player, code: status)
        }
    }

    // MARK: - Descriptors

    /// An object specifier for a property of a container, as AppleScript's `<property> of
    /// <container>`. The application itself is the null descriptor.
    private static func property(_ code: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let specifier =
            NSAppleEventDescriptor.record().coerce(toDescriptorType: DescType(typeObjectSpecifier))
            ?? NSAppleEventDescriptor.record()
        specifier.setDescriptor(
            NSAppleEventDescriptor(typeCode: DescType(cProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
        specifier.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        specifier.setDescriptor(
            NSAppleEventDescriptor(enumCode: DescType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        specifier.setDescriptor(
            NSAppleEventDescriptor(typeCode: FourCC.code(code)), forKeyword: AEKeyword(keyAEKeyData))
        return specifier
    }

    /// A number as seconds or milliseconds, from a real or an integer. Nil for a missing value.
    private static func double(_ descriptor: NSAppleEventDescriptor) -> Double? {
        guard let number = descriptor.coerce(toDescriptorType: DescType(typeIEEE64BitFloatingPoint)) else {
            return nil
        }
        let value = number.doubleValue
        return value.isFinite && value >= 0 ? value : nil
    }
}
