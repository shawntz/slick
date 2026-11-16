import Foundation
import Host
import Kit
import Testing

@testable import SlickApp

/// The app's property list template, read the way scripts/info-plist.sh fills it.
@Suite("Property list", .timeLimit(.minutes(1)))
struct InfoPlistTests {
    static var template: URL {
        URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../../support/Info.plist.in")
            .standardizedFileURL
    }

    /// The template with every token filled, parsed.
    static func plist() throws -> [String: Any] {
        var text = try String(contentsOf: template, encoding: .utf8)
        for token in ["BRAND_NAME", "BRAND_BUNDLE_ID", "BRAND_URL_SCHEME", "MIN_MACOS", "VERSION", "BUILD_NUMBER"] {
            text = text.replacingOccurrences(of: "@\(token)@", with: "x")
        }
        let value = try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil)
        return try #require(value as? [String: Any])
    }

    /// Plain http reaches a server on this Mac, such as a local model server at localhost, and
    /// nothing wider: no arbitrary loads, no exception domains.
    @Test func appTransportSecurityAllowsLocalNetworkingOnly() throws {
        let plist = try Self.plist()
        let ats = try #require(plist["NSAppTransportSecurity"] as? [String: Any])
        #expect(Set(ats.keys) == ["NSAllowsLocalNetworking"])
        #expect(ats["NSAllowsLocalNetworking"] as? Bool == true)
        let reason = try #require(plist["NSLocalNetworkUsageDescription"] as? String)
        #expect(reason.hasSuffix("."))
        #expect(reason.contains("AI settings"))
        #expect(reason.contains("shell command"), "a shell command the user runs can reach the network too")
    }

    /// The keys of the folders macOS guards. Each one's text names every part of the app that reads
    /// there: File Search, a notes folder the user chose, and shell commands and scripts.
    static let folderKeys = [
        "NSDesktopFolderUsageDescription", "NSDocumentsFolderUsageDescription", "NSDownloadsFolderUsageDescription",
        "NSRemovableVolumesUsageDescription", "NSNetworkVolumesUsageDescription",
        "NSFileProviderDomainUsageDescription",
    ]

    /// The sentences of a usage text.
    static func sentenceCount(_ text: String) -> Int {
        text.components(separatedBy: ". ").count
    }

    /// macOS shows one text for a folder, whatever reads it, so the text covers every reader in
    /// one or two sentences.
    @Test func theFolderTextsNameEveryReader() throws {
        let plist = try Self.plist()
        for key in Self.folderKeys {
            let text = try #require(plist[key] as? String, "\(key) is missing")
            #expect(text.contains("File Search"), "\(key)")
            #expect(text.contains("for your notes"), "\(key)")
            #expect(text.contains("shell command or script you run"), "\(key)")
            #expect(Self.sentenceCount(text) <= 2, "\(key)")
        }
        let iCloud = try #require(plist["NSFileProviderDomainUsageDescription"] as? String)
        #expect(iCloud.contains("downloads nothing"))
    }

    /// The Apple Events text names each app the launcher sends events to, Media Controls' players
    /// among them, and says that commands the user runs may send their own.
    @Test func theAppleEventsTextNamesEveryTarget() throws {
        let text = try #require(try Self.plist()["NSAppleEventsUsageDescription"] as? String)
        for name in [
            "Finder", "System Events", "login window", "Music", "Spotify", "Script commands", "shell commands",
        ] {
            #expect(text.contains(name), "\(name)")
        }
        #expect(Self.sentenceCount(text) <= 2)
    }

    static var supportFolder: URL { template.deletingLastPathComponent() }

    /// The usage text keys macOS reads for each permission. macOS ends an app that asks for a
    /// permission whose key is missing. Accessibility, Input Monitoring, Screen Recording, Full Disk
    /// Access and Paste from Other Apps have no key: the user grants them in System Settings.
    static func usageKeys(for permission: Permission) -> [String] {
        switch permission {
        case .accessibility, .inputMonitoring, .screenRecording, .fullDiskAccess, .pasteboard: []
        case .calendars: ["NSCalendarsFullAccessUsageDescription"]
        case .reminders: ["NSRemindersFullAccessUsageDescription"]
        case .contacts: ["NSContactsUsageDescription"]
        case .location: ["NSLocationUsageDescription", "NSLocationWhenInUseUsageDescription"]
        case .automation: ["NSAppleEventsUsageDescription"]
        case .protectedFolder(let folder):
            switch folder {
            case .desktop: ["NSDesktopFolderUsageDescription"]
            case .documents: ["NSDocumentsFolderUsageDescription"]
            case .downloads: ["NSDownloadsFolderUsageDescription"]
            case .removableVolumes: ["NSRemovableVolumesUsageDescription"]
            case .networkVolumes: ["NSNetworkVolumesUsageDescription"]
            case .iCloudDrive: ["NSFileProviderDomainUsageDescription"]
            }
        }
    }

    /// The entitlement the hardened runtime needs before macOS even asks, by permission.
    static func entitlement(for permission: Permission) -> String? {
        switch permission {
        case .calendars, .reminders: "com.apple.security.personal-information.calendars"
        case .contacts: "com.apple.security.personal-information.addressbook"
        case .location: "com.apple.security.personal-information.location"
        case .automation: "com.apple.security.automation.apple-events"
        default: nil
        }
    }

    /// Every permission any registered feature can ask for.
    @MainActor static var permissions: Set<Permission> {
        Set(Features.registrations.flatMap { $0.manifest.permissions.map(\.permission) })
    }

    /// Every permission a feature can ask for has a plain sentence that names what the launcher does
    /// with it, and no usage text is left for a permission no feature asks for.
    @MainActor @Test func everyPermissionAFeatureCanAskForHasItsUsageText() throws {
        let plist = try Self.plist()
        var wanted = Set<String>()
        for permission in Self.permissions {
            for key in Self.usageKeys(for: permission) {
                wanted.insert(key)
                let text = try #require(plist[key] as? String, "\(key) is missing for \(permission.displayName)")
                #expect(text.hasPrefix("x "), "\(key) does not start with the app's name")
                #expect(text.hasSuffix("."), "\(key) is not a sentence")
                #expect(!text.contains("\u{2014}"), "\(key) has a dash")
            }
        }
        let present = Set(plist.keys.filter { $0.hasSuffix("UsageDescription") })
        // AI's local model server is a network connection, not a feature permission.
        #expect(present.subtracting(wanted) == ["NSLocalNetworkUsageDescription"])
        #expect(wanted.isSubset(of: present))
    }

    /// The release and debug entitlements grant what the hardened runtime needs for those
    /// permissions and nothing else; debug adds only the debugger's.
    @MainActor @Test func theEntitlementsCoverEveryPermissionAndNothingMore() throws {
        let wanted = Set(Self.permissions.compactMap(Self.entitlement))
        for (file, extra) in [("release", Set<String>()), ("debug", ["com.apple.security.get-task-allow"])] {
            let data = try Data(contentsOf: Self.supportFolder.appending(path: "\(file).entitlements"))
            let value = try PropertyListSerialization.propertyList(from: data, format: nil)
            let entitlements = try #require(value as? [String: Bool])
            #expect(Set(entitlements.keys) == wanted.union(extra), "\(file)")
            #expect(entitlements.values.allSatisfy { $0 })
        }
    }
}
