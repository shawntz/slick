import Apps
import Clipboard
import Emoji
import Host
import Kit
import Quicklinks
import Scripts
import Snippets
import SystemCommands
import Windows

/// Every feature the app registers, in the order settings shows them. Add a feature with one line
/// here, one `import` above and one package line in Package.swift.
enum Features {
    static let types: [any Feature.Type] = [
        AppsFeature.self,
        ClipboardHistoryFeature.self,
        SnippetsFeature.self,
        QuicklinksFeature.self,
        EmojiFeature.self,
        WindowsFeature.self,
        SystemFeature.self,
        ScriptsFeature.self,
    ]

    /// One registration per feature, made with the feature's own `init(context:)`.
    static var registrations: [FeatureRegistration] {
        types.map { FeatureRegistration($0) }
    }
}
