import Foundation
import Kit

/// Example 1 of docs/FEATURES.md: the smallest useful feature. One command, no view.
final class UUIDFeature: Feature {
    static let manifest = FeatureManifest(id: "uuid", name: "UUID", icon: .symbol("number"))

    init(context: FeatureContext) {}

    var commands: [Command] {
        [
            Command(id: "copy-uuid", title: "Copy UUID", icon: .symbol("doc.on.doc")) { context in
                await context.pasteboard.copy(UUID().uuidString)
                return .close(hud: "Copied UUID")
            }
        ]
    }
}
