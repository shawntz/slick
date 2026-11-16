import Foundation
import Kit

/// What the General pane and onboarding say about updates.
enum UpdateStrings {
    static let section = "Updates"

    /// The switch, in the General pane and on onboarding's last step.
    static let automaticTitle = "Check for Updates Automatically"

    /// Under the switch: what a check sends, and to whom.
    static var whatIsSent: String {
        "Once a day, \(Brand.name) asks GitHub for a new version. The request sends only the version numbers of \(Brand.name) and its updater."
    }

    static let checkNow = "Check Now"

    /// Names the update a scheduled check found, which waits until the person looks at it.
    static func waiting(_ version: String) -> String {
        "\(Brand.name) \(version) is available."
    }

    /// Opens the updater's window on the update that waits.
    static let showUpdate = "Show Update…"

    /// The General pane of a build that cannot update itself.
    static var builtFromSource: String {
        "This copy of \(Brand.name) was built from source. To update it, pull with git and build again."
    }

    /// When the last check was, or that there was none.
    static func lastCheck(_ date: Date?) -> String {
        guard let date else { return "Not checked yet" }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
