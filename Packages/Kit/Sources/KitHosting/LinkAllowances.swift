import Foundation
import Kit

/// The commands the user lets links run without asking, each with the exact argument values it
/// allows and the command's title at the time.
///
/// App's deep link router adds one when the user chooses Always Allow on the page that asks. A
/// link then runs without asking only when an allowance names the same command, the same
/// arguments and the title the command still has. Any other link asks again, so a web page cannot
/// reuse an allowance with arguments of its own, and a new script saved where an allowed one was,
/// with another title, is not allowed. The router drops allowances whose command is gone. The
/// settings window lists them and removes them.
///
/// They live under ``namespace``, apart from ``HostSettings``:
///
/// ```swift
/// let links = LinkAllowances.settings(services.settings)
/// let allowed = LinkAllowances.entries(in: links)
/// ```
public enum LinkAllowances {
    /// The namespace of ``key``. It contains a ".", which no feature ID may.
    public static let namespace = "app.links"
    /// Every allowance, as ``Entry/storedValue`` text.
    public static let key = SettingKey("allowedCommands", default: [String]())

    /// The settings that hold ``key``, over a settings service.
    public static func settings(_ service: any SettingsService) -> FeatureSettings {
        FeatureSettings(featureID: namespace, service: service)
    }

    /// One command links may run without asking, with exactly these arguments.
    public struct Entry: Hashable, Sendable {
        public var command: ItemID
        /// The argument values by name. Empty allows only a link that passes none.
        public var arguments: [String: String]
        /// The command's title when the user allowed it.
        public var title: String

        public init(command: ItemID, arguments: [String: String], title: String) {
            self.command = command
            self.arguments = arguments
            self.title = title
        }

        /// The stored text: the command's ID, then `?` and the arguments as `name=value` pairs in
        /// name order joined by `&`, then `#` and the title. Every ID, name, value and title is
        /// percent-encoded, so none of them can end its part early.
        public var storedValue: String {
            var text = Self.encode(command.rawValue)
            if !arguments.isEmpty {
                let pairs = arguments.keys.sorted().map { Self.encode($0) + "=" + Self.encode(arguments[$0] ?? "") }
                text += "?" + pairs.joined(separator: "&")
            }
            return text + "#" + Self.encode(title)
        }

        /// Reads ``storedValue`` text. Nil for text it did not write.
        public init?(storedValue: String) {
            guard let hash = storedValue.firstIndex(of: "#"),
                let title = storedValue[storedValue.index(after: hash)...].removingPercentEncoding
            else { return nil }
            let head = storedValue[..<hash]
            let idText: Substring
            var arguments: [String: String] = [:]
            if let question = head.firstIndex(of: "?") {
                idText = head[..<question]
                for pair in head[head.index(after: question)...].split(separator: "&", omittingEmptySubsequences: false)
                {
                    let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard parts.count == 2, let name = parts[0].removingPercentEncoding, !name.isEmpty,
                        let value = parts[1].removingPercentEncoding, arguments[name] == nil
                    else { return nil }
                    arguments[name] = value
                }
                guard !arguments.isEmpty else { return nil }
            } else {
                idText = head
            }
            guard let raw = idText.removingPercentEncoding, let command = ItemID(rawValue: raw) else { return nil }
            self.init(command: command, arguments: arguments, title: title)
        }

        /// Letters, digits and `-._~` stay; everything else is percent-encoded.
        private static let kept = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

        private static func encode(_ text: String) -> String {
            text.addingPercentEncoding(withAllowedCharacters: kept) ?? ""
        }
    }

    /// Every allowance in the order stored. Text that cannot be read is left out.
    public static func entries(in settings: FeatureSettings) -> [Entry] {
        settings[key].compactMap(Entry.init(storedValue:))
    }

    /// True when an allowance names exactly this command, these arguments and this title.
    public static func allows(
        _ command: ItemID, arguments: [String: String], title: String, in settings: FeatureSettings
    ) -> Bool {
        entries(in: settings).contains(Entry(command: command, arguments: arguments, title: title))
    }

    /// Adds an allowance, unless it is stored already.
    public static func add(_ entry: Entry, in settings: FeatureSettings) {
        let stored = entries(in: settings)
        guard !stored.contains(entry) else { return }
        write(stored + [entry], in: settings)
    }

    /// Removes an allowance.
    public static func remove(_ entry: Entry, in settings: FeatureSettings) {
        write(entries(in: settings).filter { $0 != entry }, in: settings)
    }

    /// Keeps only the allowances that `keep` accepts, and drops text that cannot be read. Returns
    /// how many it dropped. Writes nothing when nothing changes.
    @discardableResult
    public static func removeAll(in settings: FeatureSettings, keeping keep: (Entry) -> Bool) -> Int {
        let raw = settings[key]
        let kept = raw.compactMap(Entry.init(storedValue:)).filter(keep)
        guard kept.count != raw.count else { return 0 }
        write(kept, in: settings)
        return raw.count - kept.count
    }

    private static func write(_ entries: [Entry], in settings: FeatureSettings) {
        settings[key] = entries.map(\.storedValue)
    }
}
