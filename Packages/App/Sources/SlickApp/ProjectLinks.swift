import Foundation
import SettingsUI

/// Where the project lives, for the links in the settings window's About pane. The pane opens
/// each through the workspace service.
enum ProjectLinks {
    /// The source repository.
    static let repository = link("https://github.com/shawntz/slick")
    /// The website.
    static let website = link("https://slick.computer")

    /// Repository, Website, License, Third-Party Notices and Security Policy, in that order.
    static var about: [AboutInfo.Link] {
        [
            AboutInfo.Link(title: "Repository", url: repository),
            AboutInfo.Link(title: "Website", url: website),
            AboutInfo.Link(title: "License", url: repository.appending(path: "blob/main/LICENSE")),
            AboutInfo.Link(
                title: "Third-Party Notices", url: repository.appending(path: "blob/main/THIRD-PARTY-NOTICES.md")),
            AboutInfo.Link(title: "Security Policy", url: repository.appending(path: "security/policy")),
        ]
    }

    private static func link(_ text: String) -> URL {
        guard let url = URL(string: text) else { preconditionFailure("not a URL: \(text)") }
        return url
    }
}
