import Kit

/// The user's fallback list: which commands with a ``Kit/Fallback`` are on, and in what order.
///
/// It lives in ``ItemPreferences`` with aliases and favorites. Root search shows the fallbacks that
/// are on, in this order, under every typed query. The settings window shows every fallback with a
/// switch and lets the user move it. Both read the list through ``list(_:)``, or
/// ``FeatureDirectory/fallbacks(_:)``, so they always agree.
///
/// A fallback the user never touched follows its ``Kit/Fallback/startsOn``, and one the user never
/// moved keeps its place in registration order after the ones the user placed.
public struct FallbackChoices: Hashable, Sendable {
    /// Fallback commands in the user's order, by `cmd:` ID. Commands not named here follow, in
    /// registration order.
    public var order: [ItemID]
    /// The user's switch for each fallback command they set one for. A command without one follows
    /// its ``Kit/Fallback/startsOn``.
    public var switches: [ItemID: Bool]

    public init(order: [ItemID] = [], switches: [ItemID: Bool] = [:]) {
        self.order = order
        self.switches = switches
    }

    /// True while the user has set no switch and no order.
    public var isEmpty: Bool {
        order.isEmpty && switches.isEmpty
    }

    /// Whether a fallback is on: the user's switch, or `startsOn` until the user sets one.
    public func isOn(_ id: ItemID, startsOn: Bool) -> Bool {
        switches[id] ?? startsOn
    }

    /// The given commands in the user's order: first the ones ``order`` names, in that order, then
    /// the rest in the order given. IDs in ``order`` that are not given are left out, and each
    /// command shows once.
    public func arranged(_ ids: [ItemID]) -> [ItemID] {
        let given = Set(ids)
        var seen: Set<ItemID> = []
        var result: [ItemID] = []
        result.reserveCapacity(ids.count)
        for id in order where given.contains(id) && seen.insert(id).inserted {
            result.append(id)
        }
        for id in ids where seen.insert(id).inserted {
            result.append(id)
        }
        return result
    }

    /// Every command that declares a fallback and is on, in the user's order, each with whether its
    /// fallback is on. Commands that are off or declare no fallback are left out.
    ///
    /// - Parameter commands: Commands in registration order, as ``FeatureEntry/commands`` lists them.
    public func list(_ commands: [CommandEntry]) -> [FallbackListEntry] {
        var byID: [ItemID: CommandEntry] = [:]
        var ids: [ItemID] = []
        for entry in commands where entry.isEnabled && entry.command.fallback != nil && byID[entry.id] == nil {
            byID[entry.id] = entry
            ids.append(entry.id)
        }
        return arranged(ids).compactMap { id in
            guard let entry = byID[id], let fallback = entry.command.fallback else { return nil }
            return FallbackListEntry(command: entry, isOn: isOn(id, startsOn: fallback.startsOn))
        }
    }

    /// Sets the user's switch for one fallback.
    public mutating func setOn(_ isOn: Bool, for id: ItemID) {
        switches[id] = isOn
    }

    /// Forgets the user's switch for one fallback, so it follows ``Kit/Fallback/startsOn`` again.
    public mutating func resetSwitch(for id: ItemID) {
        switches[id] = nil
    }

    /// Makes `ids` the user's order, as the settings window does after the user moved a fallback.
    /// Pass every fallback the window lists, in the new order. Repeated IDs after the first are
    /// dropped.
    public mutating func setOrder(_ ids: [ItemID]) {
        var seen: Set<ItemID> = []
        order = ids.filter { seen.insert($0).inserted }
    }
}

extension FallbackChoices: Codable {
    private enum CodingKeys: String, CodingKey {
        case order, switches
    }

    /// Decodes IDs from their plain string form and drops any that do not parse, so one bad entry in
    /// a hand-edited file loses only itself.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let order = try container.decodeIfPresent([String].self, forKey: .order) ?? []
        let switches = try container.decodeIfPresent([String: Bool].self, forKey: .switches) ?? [:]
        self.order = order.compactMap(ItemID.init(rawValue:))
        var parsed: [ItemID: Bool] = [:]
        for (raw, isOn) in switches {
            if let id = ItemID(rawValue: raw) { parsed[id] = isOn }
        }
        self.switches = parsed
    }

    /// Encodes IDs as plain strings: the order as an array, the switches as an object.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(order.map(\.rawValue), forKey: .order)
        var raw: [String: Bool] = [:]
        for (id, isOn) in switches { raw[id.rawValue] = isOn }
        try container.encode(raw, forKey: .switches)
    }
}

/// One command in the fallback list, as root search and the settings window read it.
public struct FallbackListEntry: Identifiable, Sendable {
    /// The command, with its ``Kit/Command/fallback``.
    public var command: CommandEntry
    /// True when root search shows this fallback.
    public var isOn: Bool

    /// The command's `cmd:` ID.
    public var id: ItemID { command.id }

    public init(command: CommandEntry, isOn: Bool) {
        self.command = command
        self.isOn = isOn
    }
}

extension FeatureDirectory {
    /// Every command of a feature that is on that declares a fallback and is on itself, in the
    /// user's order, each with whether its fallback is on. Root search shows the ones that are on.
    /// The settings window lists them all, with a switch each.
    public func fallbacks(_ choices: FallbackChoices) -> [FallbackListEntry] {
        choices.list(enabledFeatures.flatMap(\.commands))
    }
}
