import Foundation
import Kit

/// The about pane's text and links.
struct AboutModel {
    let info: AboutInfo
    private let context: SettingsContext

    init(info: AboutInfo, context: SettingsContext) {
        self.info = info
        self.context = context
    }

    var name: String { Brand.name }

    var versionText: String {
        info.build.map { "Version \(info.version) (\($0))" } ?? "Version \(info.version)"
    }

    var licenseText: String {
        "\(Brand.name) is open source under the \(info.license)."
    }

    var privacyText: String {
        "\(Brand.name) sends nothing about you anywhere. There is no telemetry and no account."
    }

    /// Opens a link through the workspace service, so scenarios and tests record it instead. A
    /// failure shows a toast.
    func open(_ link: AboutInfo.Link) async {
        do {
            try await context.services.workspace.open(link.url)
        } catch {
            context.toasts.show(error, title: "Could Not Open \(link.title)")
        }
    }
}
