import Kit

/// The about pane's text.
struct AboutModel {
    let info: AboutInfo

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
}
