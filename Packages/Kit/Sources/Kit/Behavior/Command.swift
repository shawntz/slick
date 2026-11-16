import Foundation

/// An entry in root search that runs something: a no-view command such as "Left Half", or a command
/// that opens a page such as "Clipboard History".
///
/// A command's root ID is `cmd:<feature id>.<command id>` (see ``ItemID/command(feature:command:)``).
/// The user can give any command an alias, a hotkey or turn it off in settings; the host handles
/// that, so features only declare defaults. When a command disappears, as a script does during a
/// checkout, the host keeps its alias and hotkey for 30 days in case it comes back.
///
/// The host runs ``run`` as it runs an action handler: permissions, then the confirmation, then the
/// handler under ``runPolicy``; a thrown error shows a failure toast or HUD.
public struct Command: Identifiable, Sendable {
    /// Runs the command and says what the panel does next.
    public typealias Run = @MainActor @Sendable (ActionContext) async throws -> ActionOutcome

    /// Unique within the feature: letters, digits, ".", "-" and "_". Changing it loses the user's
    /// alias, hotkey and learning for the command. ``stableID(_:name:uniqueKey:)`` makes one from
    /// free text such as a file name.
    public var id: String
    public var title: String
    public var subtitle: String?
    public var icon: Icon?
    /// Extra words root search matches.
    public var keywords: [String]
    /// Up to three inline arguments, shown as fields in the search bar after the title.
    public var arguments: [CommandArgument]
    /// Permissions the command needs. When one is missing, the host explains why and offers to grant
    /// it instead of running the command, opening the panel if a hotkey started it.
    public var requires: [Permission]
    /// When set, the host asks before running the command, opening the panel if a hotkey started it.
    public var confirmation: Confirmation?
    /// A hotkey suggested in settings. Nil for almost every command: the user assigns hotkeys. For a
    /// set of hotkeys, such as a window layout scheme, declare a ``HotkeyPreset``.
    public var suggestedHotkey: KeyCombo?
    /// When set, the command can appear in the fallback list under root results. The typed text
    /// arrives as ``ActionContext/query`` and fills the first argument when there is one.
    public var fallback: Fallback?
    /// When true, Tab in root search runs this command with the typed text, as for a fallback. The
    /// user picks one such command in settings; this marks the candidates. A selected row's
    /// ``Row/completion`` wins over it.
    public var takesRootQueryOnTab: Bool
    /// A subtitle root search refreshes while the row is visible, such as a script's inline output.
    public var liveSubtitle: LiveSubtitle?
    /// False hides the command from root search; it can still run from a hotkey, a deep link or
    /// another command.
    public var showsInRoot: Bool
    /// False keeps the command out of deep links: the app refuses a link that names it, even when the
    /// user chose Always Allow for it. Set it on a hidden command that acts at once, such as one that
    /// pastes, so a web page can never start it. ``FeatureValidator/validate(_:)`` reports a hidden
    /// command with no ``confirmation`` that leaves it true.
    public var allowsDeepLinks: Bool
    /// What happens when the command starts again before an earlier run has finished.
    public var runPolicy: RunPolicy
    /// More actions for the command's row in root search, such as Edit or Delete for a quicklink.
    /// The action panel shows Run, then these, then the host's own entries such as alias and
    /// hotkey. Built when the panel opens, so keep it cheap. Set it with ``withRowActions(_:)``.
    public var rowActions: (@MainActor @Sendable () -> [Action])?
    public var run: Run

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        icon: Icon? = nil,
        keywords: [String] = [],
        arguments: [CommandArgument] = [],
        requires: [Permission] = [],
        confirmation: Confirmation? = nil,
        suggestedHotkey: KeyCombo? = nil,
        fallback: Fallback? = nil,
        takesRootQueryOnTab: Bool = false,
        liveSubtitle: LiveSubtitle? = nil,
        showsInRoot: Bool = true,
        runPolicy: RunPolicy = .serial,
        allowsDeepLinks: Bool = true,
        run: @escaping Run
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.keywords = keywords
        self.arguments = arguments
        self.requires = requires
        self.confirmation = confirmation
        self.suggestedHotkey = suggestedHotkey
        self.fallback = fallback
        self.takesRootQueryOnTab = takesRootQueryOnTab
        self.liveSubtitle = liveSubtitle
        self.showsInRoot = showsInRoot
        self.runPolicy = runPolicy
        self.allowsDeepLinks = allowsDeepLinks
        self.run = run
    }

    /// A copy of the command whose row in root search offers these actions after Run.
    public func withRowActions(_ actions: @escaping @MainActor @Sendable () -> [Action]) -> Command {
        var copy = self
        copy.rowActions = actions
        return copy
    }

    /// The command's root ID for the given feature.
    public func itemID(feature featureID: String) -> ItemID {
        .command(feature: featureID, command: id)
    }

    /// A valid command ID for something named by free text, such as a script file: `prefix.slug-hash`.
    ///
    /// The slug is the name folded to lowercase ASCII letters and digits, so it reads well and does
    /// not change with how the file system normalizes accents. The hash is 8 hex digits of FNV-1a over
    /// `uniqueKey`, such as the file's full path, so two items with the same name stay apart.
    public static func stableID(_ prefix: String, name: String, uniqueKey: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var slug = ""
        for scalar in folded.unicodeScalars {
            if scalar.isASCII && (("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty && !slug.hasSuffix("-") {
                slug += "-"
            }
        }
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40)
        let hash = String(FNV1a.hash64(uniqueKey) & 0xFFFF_FFFF, radix: 16)
        let padded = String(repeating: "0", count: 8 - hash.count) + hash
        return prefix + "." + (trimmed.isEmpty ? "" : trimmed + "-") + padded
    }
}
