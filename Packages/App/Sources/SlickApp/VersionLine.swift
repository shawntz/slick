import Kit

/// The line `--version` prints: the name, the version and the build number, such as
/// "Slick 0.1.0 (412)". `scripts/check-release.sh` runs the shipped executable with `--version` and
/// expects exactly this line for the release it checks.
nonisolated enum VersionLine {
    /// The line for an Info.plist dictionary. Outside a bundle, as `swift run` starts the app, the
    /// version reads "Development" and there is no build number.
    static func text(info: [String: Any]) -> String {
        guard let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty else {
            return "\(Brand.name) Development"
        }
        guard let build = info["CFBundleVersion"] as? String, !build.isEmpty else {
            return "\(Brand.name) \(version)"
        }
        return "\(Brand.name) \(version) (\(build))"
    }
}
