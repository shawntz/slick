import Foundation

/// Checks what a feature declares against the rules every feature must follow. The host runs it at
/// registration and in `--selftest`; `FeatureHarness` exposes it so a feature's tests fail first.
@MainActor public enum FeatureValidator {
    /// Every problem found, empty when the feature is valid.
    public static func validate(_ feature: any Feature) -> [FeatureIssue] {
        let manifest = type(of: feature).manifest
        let commands = feature.commands
        var issues = validate(manifest)
        issues += validate(commands: commands, manifest: manifest)
        issues += validateNamespaces(feature)
        issues += validateStability(feature)
        issues += validate(presets: feature.hotkeyPresets, commands: commands)
        issues += duplicates(in: feature.suggestionTriggers.map(\.id)).map {
            "suggestion trigger \"\($0)\" is declared twice"
        }
        let declared = Set(manifest.permissions.map(\.permission))
        for trigger in feature.suggestionTriggers {
            for permission in trigger.requires where !declared.contains(permission) {
                issues.append(
                    "trigger \"\(trigger.id)\" requires \(permission.displayName), which the manifest does not list")
            }
        }
        for permission in feature.status?.requires ?? [] where !declared.contains(permission) {
            issues.append("the status requires \(permission.displayName), which the manifest does not list")
        }
        return issues
    }

    /// Checks a manifest alone.
    public static func validate(_ manifest: FeatureManifest) -> [FeatureIssue] {
        var issues: [FeatureIssue] = []
        if !isValidFeatureID(manifest.id) {
            issues.append(
                "feature id \"\(manifest.id)\" must be a lowercase letter, then lowercase letters, digits or \"-\"")
        }
        if manifest.name.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append("feature \"\(manifest.id)\" has no name")
        }
        issues += duplicates(in: manifest.permissions.map(\.permission)).map {
            "permission \($0.displayName) is listed twice"
        }
        return issues
    }

    /// Checks commands, and the row actions they declare, against their feature's manifest.
    public static func validate(commands: [Command], manifest: FeatureManifest) -> [FeatureIssue] {
        var issues: [FeatureIssue] = []
        let declared = Set(manifest.permissions.map(\.permission))
        for command in commands {
            let name = "command \"\(command.id)\""
            if command.id.isEmpty || !command.id.allSatisfy(isCommandIDCharacter) {
                issues.append("\(name): id must use letters, digits, \".\", \"-\" or \"_\"")
            }
            if command.title.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append("\(name) has no title")
            }
            if command.arguments.count > 3 {
                issues.append("\(name) has \(command.arguments.count) arguments; the search bar holds at most 3")
            }
            issues += duplicates(in: command.arguments.map(\.name)).map {
                "\(name): argument \"\($0)\" is declared twice"
            }
            for argument in command.arguments {
                if case .dropdown(let options) = argument.kind, options.isEmpty {
                    issues.append("\(name): dropdown argument \"\(argument.name)\" has no options")
                }
            }
            for permission in command.requires where !declared.contains(permission) {
                issues.append("\(name) requires \(permission.displayName), which the manifest does not list")
            }
            if let rowActions = command.rowActions {
                issues += validate(actions: rowActions(), manifest: manifest).map { "\(name): \($0.message)" }
            }
        }
        issues += duplicates(in: commands.map(\.id)).map { "command \"\($0)\" is declared twice" }
        return issues
    }

    /// Checks that each action's permissions are listed in the manifest, so the host has a reason to
    /// show, and that IDs are unique in the list. `FeatureHarness` runs it on every action list it
    /// hands out.
    public static func validate(actions: [Action], manifest: FeatureManifest) -> [FeatureIssue] {
        let declared = Set(manifest.permissions.map(\.permission))
        var issues: [FeatureIssue] = []
        for action in actions {
            for permission in action.requires where !declared.contains(permission) {
                issues.append(
                    "action \"\(action.id)\" requires \(permission.displayName), which the manifest does not list")
            }
        }
        issues += duplicates(in: actions.map(\.id)).map { "action \"\($0)\" appears twice in one list" }
        return issues
    }

    /// Checks a form's permissions against the manifest.
    public static func validate(form: FormPage, manifest: FeatureManifest) -> [FeatureIssue] {
        let declared = Set(manifest.permissions.map(\.permission))
        return form.requires.filter { !declared.contains($0) }.map {
            "form \"\(form.title)\" requires \($0.displayName), which the manifest does not list"
        }
    }

    /// True for a lowercase ASCII letter, then lowercase letters, digits or "-", at most 40 characters.
    public static func isValidFeatureID(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, ("a"..."z").contains(first), id.unicodeScalars.count <= 40 else {
            return false
        }
        return id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// Namespaces must be valid, not Root's, and owned by one object each. One object may be a
    /// catalog source, a live provider and a suggestion trigger under the same namespace.
    private static func validateNamespaces(_ feature: any Feature) -> [FeatureIssue] {
        var owners: [(namespace: String, owner: ObjectIdentifier)] = []
        owners += feature.catalogSources.map { ($0.namespace, ObjectIdentifier($0)) }
        owners += feature.liveProviders.map { ($0.namespace, ObjectIdentifier($0.actionProvider)) }
        owners += feature.suggestionTriggers.map { ($0.namespace, ObjectIdentifier($0)) }
        var issues: [FeatureIssue] = []
        var ownerByNamespace: [String: ObjectIdentifier] = [:]
        var reported = Set<String>()
        let featureID = type(of: feature).manifest.id
        for (namespace, owner) in owners {
            if !ItemID.isValidNamespace(namespace) {
                issues.append("namespace \"\(namespace)\" is invalid")
            } else if !ItemID.ReservedNamespace.allows(namespace, forFeature: featureID) {
                issues.append("namespace \"\(namespace)\" is reserved for root search")
            }
            if let existing = ownerByNamespace[namespace], existing != owner, reported.insert(namespace).inserted {
                issues.append("namespace \"\(namespace)\" is used by more than one source")
            }
            ownerByNamespace[namespace] = ownerByNamespace[namespace] ?? owner
        }
        return issues
    }

    /// Sources, providers and triggers must be the same objects on every read: the host keeps them,
    /// and a provider made anew per read loses its state and allocates on the keystroke path.
    private static func validateStability(_ feature: any Feature) -> [FeatureIssue] {
        // Both reads stay alive while they are compared, so a new object cannot reuse an old address.
        func differ(_ first: [AnyObject], _ second: [AnyObject]) -> Bool {
            first.count != second.count || zip(first, second).contains { $0 !== $1 }
        }
        var issues: [FeatureIssue] = []
        if differ(feature.catalogSources, feature.catalogSources) {
            issues.append("catalogSources returns new objects on each read; keep them in stored properties")
        }
        if differ(feature.liveProviders.map(\.actionProvider), feature.liveProviders.map(\.actionProvider)) {
            issues.append("liveProviders returns new objects on each read; keep them in stored properties")
        }
        if differ(feature.suggestionTriggers, feature.suggestionTriggers) {
            issues.append("suggestionTriggers returns new objects on each read; keep them in stored properties")
        }
        return issues
    }

    private static func validate(presets: [HotkeyPreset], commands: [Command]) -> [FeatureIssue] {
        let commandIDs = Set(commands.map(\.id))
        var issues = duplicates(in: presets.map(\.id)).map { FeatureIssue("hotkey preset \"\($0)\" is declared twice") }
        for preset in presets {
            for commandID in preset.bindings.keys.sorted() where !commandIDs.contains(commandID) {
                issues.append("hotkey preset \"\(preset.id)\" binds \"\(commandID)\", which is not a command")
            }
            let combos = preset.bindings.sorted { $0.key < $1.key }.map(\.value)
            issues += duplicates(in: combos).map {
                "hotkey preset \"\(preset.id)\" uses \($0.displayString) for more than one command"
            }
        }
        return issues
    }

    private static func isCommandIDCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || ".-_".contains(character))
    }

    private static func duplicates<Element: Hashable>(in elements: [Element]) -> [Element] {
        var seen = Set<Element>()
        var repeated: [Element] = []
        for element in elements where !seen.insert(element).inserted && !repeated.contains(element) {
            repeated.append(element)
        }
        return repeated
    }
}

/// One problem with a feature's declarations.
public struct FeatureIssue: Hashable, Sendable, CustomStringConvertible, ExpressibleByStringInterpolation {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public init(stringLiteral value: String) {
        self.message = value
    }

    public var description: String { message }
}
