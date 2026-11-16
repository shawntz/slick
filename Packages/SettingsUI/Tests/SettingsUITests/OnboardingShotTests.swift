import AppKit
import Foundation
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import SwiftUI
import Testing

@testable import SettingsUI

/// Renders every onboarding step with what a real first launch shows, off screen, at two pixels per
/// point, in light and in dark: two optional features whose texts differ in length, the seventeen
/// permissions a first launch with File Search on lists, some with two or three reasons, one
/// allowed, one skipped and two that wait for their app, the seven built-in themes, and the hotkey
/// step while Spotlight's shortcut uses the launcher's keys.
///
/// Set `ONBOARDING_SHOTS` to a folder to write one PNG per step and appearance there. Without it
/// the test still renders every step and checks that each picture has content.
@MainActor @Suite(.timeLimit(.minutes(2))) struct OnboardingShotTests {
    private static let folder = ProcessInfo.processInfo.environment["ONBOARDING_SHOTS"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    }

    @Test func rendersEveryStepWithFirstLaunchContent() async throws {
        let bed = FirstLaunchBed()
        bed.hotkeyStatus.startWaiting(canTurnOff: true)
        let context = bed.context()
        let model = OnboardingModel(context: context) {}
        // The switches apply when the features step is left, as when the person continues.
        await model.applyFeatureChoices()
        // What the owner saw: Full Disk Access allowed, and with it every folder but iCloud Drive.
        for permission in [Permission.accessibility, .fullDiskAccess] {
            bed.fakes.permissions.set(permission, to: .granted)
        }
        for folder in ProtectedFolder.allCases where folder != .iCloudDrive {
            bed.fakes.permissions.set(.protectedFolder(folder), to: .granted)
        }
        model.skip(.inputMonitoring)
        // iCloud Drive's Allow ended with no answer from macOS.
        bed.fakes.permissions.answer = .notDetermined
        await model.allow(.protectedFolder(.iCloudDrive))
        let view = OnboardingView(model: model, toasts: context.toasts)
        let shots: [(String, OnboardingModel.Step)] = [
            ("1-welcome", .welcome), ("2-hotkey", .hotkey), ("3-features", .features),
            ("4-permissions", .permissions), ("5-theme", .theme), ("6-done", .done),
        ]
        for (name, step) in shots {
            #expect(model.show(step), "\(name) has nothing to show")
            try write(name, view)
        }
        #expect(model.show(.permissions))
        try write("4-permissions-scrolled", view, scrolledTo: 0.45)
        try write("4-permissions-end", view, scrolledTo: 1)
        bed.updates.isAvailable = true
        #expect(model.show(.done))
        try write("6-done-with-updates", view)

        // The hotkey step's other states.
        #expect(model.show(.hotkey))
        bed.hotkeyStatus.turnOffWorks = false
        await model.next()
        try write("2-hotkey-failed", view)
        bed.hotkeyStatus.bindWaited()
        try write("2-hotkey-freed", view)
        bed.hotkeyStatus.startWaiting(KeyCombo(.upArrow, .control), owner: "Mission Control")
        try write("2-hotkey-other-shortcut", view)
        bed.hotkeyStatus.bindWaited()
        bed.hotkeyStatus.bound = nil
        let fresh = OnboardingModel(context: bed.context()) {}
        #expect(fresh.show(.hotkey))
        try write("2-hotkey-nothing-waits", OnboardingView(model: fresh, toasts: context.toasts))
    }

    @Test func rendersTheGeneralPanesHotkeyStates() throws {
        let bed = FirstLaunchBed()
        let context = bed.context()
        let model = GeneralModel(context: context)
        let size = CGSize(width: 680, height: 420)
        bed.hotkeyStatus.startWaiting(canTurnOff: true)
        try write("general-spotlight-uses-the-keys", GeneralPane(model: model), size: size)
        bed.hotkeyStatus.startWaiting(KeyCombo(.upArrow, .control), owner: "Mission Control")
        try write("general-another-shortcut", GeneralPane(model: model), size: size)
        bed.hotkeyStatus.bindWaited()
        bed.hotkeyStatus.turnedOffShortcut = TurnedOffShortcut(
            combo: KeyCombo(.space, .command), owner: "Spotlight", date: Date(timeIntervalSince1970: 1_800_000_000))
        bed.hotkeyStatus.statusChanges.send()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try write("general-turned-off", GeneralPane(model: model), size: size)
    }

    private func write<V: View>(
        _ name: String, _ view: V, size: CGSize = OnboardingView.size, scrolledTo fraction: CGFloat? = nil
    ) throws {
        for dark in [false, true] {
            let image = try #require(
                Self.render(view, dark: dark, size: size, scrolledTo: fraction), "\(name) did not render")
            #expect(PaneShotTests.hasContent(image), "\(name) rendered blank")
            guard let folder = Self.folder else { continue }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let prefix = name.hasPrefix("general") ? "" : "onboarding-"
            let file = folder.appending(path: "\(prefix)\(name)-\(dark ? "dark" : "light").png")
            let rep = NSBitmapImageRep(cgImage: image)
            try #require(rep.representation(using: .png, properties: [:])).write(to: file)
        }
    }

    /// Draws the view at two pixels per point, at the onboarding window's size, through a window
    /// placed far off every display and never ordered in. `scrolledTo` scrolls the step's list that
    /// far, from 0 at the top to 1 at the end, before drawing.
    static func render<V: View>(
        _ view: V, dark: Bool, size: CGSize = OnboardingView.size, scrolledTo fraction: CGFloat? = nil
    ) -> CGImage? {
        _ = NSApplication.shared
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.appearance = appearance
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hosting
        defer { window.close() }
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if let fraction, let scroll = scrollView(in: hosting), let document = scroll.documentView {
            let room = max(0, document.frame.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: (room * fraction).rounded()))
            scroll.reflectScrolledClipView(scroll.contentView)
            for _ in 0..<2 {
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }
        hosting.display()
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep.cgImage
    }

    /// The first scroll view in a view's tree.
    static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews {
            if let found = scrollView(in: subview) { return found }
        }
        return nil
    }
}

/// What a first launch with File Search on gives onboarding, as fakes: the features that are on by
/// default and name a permission, File Search, which onboarding suggests, and Clipboard History,
/// which is off. Names, reasons and summaries are the features' own; nothing is read from the Mac.
@MainActor final class FirstLaunchBed {
    let fakes = FakeServices(permissions: .notDetermined)
    let directory = FakeFeatureDirectory()
    let preferences: FakeItemPreferences
    let themes: ThemeStore
    let root: URL
    let hotkeyStatus = FakeLauncherHotkeyStatus()
    let updates = FakeUpdates()

    static let music = "com.apple.Music"
    static let spotify = "com.spotify.client"

    init() {
        root = FileManager.default.temporaryDirectory.appending(path: "onboarding-shots-\(UUID().uuidString)")
        preferences = FakeItemPreferences(directory: directory)
        themes = ThemeStore(folder: root.appending(path: "themes"))
        updates.isAvailable = false
        let features: [FeatureManifest] = [
            FeatureManifest(
                id: "calc", name: "Calculator", icon: .symbol("plus.forwardslash.minus"),
                permissions: [PermissionNeed(.accessibility, reason: "Paste answers into the frontmost app.")]),
            FeatureManifest(
                id: "snippets", name: "Snippets", icon: .symbol("text.badge.plus"),
                permissions: [
                    PermissionNeed(
                        .accessibility,
                        reason: "Paste snippets into the app you are using and replace typed keywords with text."),
                    PermissionNeed(.inputMonitoring, reason: "Notice when you type a snippet's keyword in any app."),
                ]),
            FeatureManifest(
                id: "windows", name: "Window Management", icon: .symbol("macwindow"),
                permissions: [
                    PermissionNeed(.accessibility, reason: "Move and resize the windows of other apps.")
                ]),
            FeatureManifest(
                id: "bookmarks", name: "Browser Bookmarks", icon: .symbol("bookmark"),
                permissions: [
                    PermissionNeed(.fullDiskAccess, reason: "Read the bookmarks of browsers that keep them private.")
                ]),
            FeatureManifest(
                id: "schedule", name: "Calendar and Reminders", icon: .symbol("calendar"),
                permissions: [
                    PermissionNeed(
                        .calendars,
                        reason: "Show your upcoming events, find their meeting links and add the events you create."),
                    PermissionNeed(
                        .reminders,
                        reason: "Show your reminders, complete or delete the ones you choose and add new ones."),
                ]),
            FeatureManifest(
                id: "people", name: "Contacts", icon: .symbol("person.crop.circle"),
                permissions: [
                    PermissionNeed(
                        .contacts, reason: "Read your contacts on this Mac, so you can find people and reach them.")
                ]),
            FeatureManifest(
                id: "media", name: "Media Controls", icon: .symbol("playpause"),
                permissions: [
                    PermissionNeed(
                        .automation(bundleID: Self.music),
                        reason: "Play, pause and skip tracks in Music, and read what is playing."),
                    PermissionNeed(
                        .automation(bundleID: Self.spotify),
                        reason: "Play, pause and skip tracks in Spotify, and read what is playing."),
                ]),
            FeatureManifest(
                id: "system", name: "System", icon: .symbol("gearshape"),
                permissions: [
                    PermissionNeed(
                        .automation(bundleID: "com.apple.finder"), reason: "Count and empty the Trash through Finder."
                    ),
                    PermissionNeed(
                        .automation(bundleID: "com.apple.systemevents"),
                        reason: "Switch between light and dark appearance through System Events."),
                    PermissionNeed(
                        .automation(bundleID: "com.apple.loginwindow"),
                        reason: "Ask macOS to log out, restart or shut down."),
                ]),
            FeatureManifest(
                id: "files", name: "File Search", icon: .symbol("doc.text.magnifyingglass"),
                summary: "Find files and folders by name, and browse folders by typing a path.",
                permissions: [
                    PermissionNeed(
                        .protectedFolder(.desktop),
                        reason: "Search the files on your Desktop, once you choose to include it."),
                    PermissionNeed(
                        .protectedFolder(.documents),
                        reason: "Search the files in your Documents folder, once you choose to include it."),
                    PermissionNeed(
                        .protectedFolder(.downloads),
                        reason: "Search the files in your Downloads folder, once you choose to include it."),
                    PermissionNeed(
                        .protectedFolder(.iCloudDrive),
                        reason:
                            "Search the files in iCloud Drive, once you choose to include it. macOS asks for it even "
                            + "with Full Disk Access, and files kept only in iCloud are listed by name, not downloaded."
                    ),
                    PermissionNeed(
                        .protectedFolder(.removableVolumes),
                        reason: "Search files on removable drives, once you choose to include them."),
                    PermissionNeed(
                        .protectedFolder(.networkVolumes),
                        reason: "Search files on network volumes, once you choose to include them."),
                    PermissionNeed(
                        .fullDiskAccess,
                        reason:
                            "Search the protected folders you choose without a prompt for each, except iCloud Drive."
                    ),
                ],
                isEnabledByDefault: false, isSuggestedInOnboarding: true),
            FeatureManifest(
                id: "clipboard", name: "Clipboard History", icon: .symbol("doc.on.clipboard"),
                summary: "Keep what you copy, search it, and paste it again later.",
                permissions: [
                    PermissionNeed(
                        .pasteboard, reason: "Read what you copy in other apps, so it can be kept in your history."),
                    PermissionNeed(.accessibility, reason: "Paste the item you choose into the app you were using."),
                ],
                isEnabledByDefault: false),
        ]
        fakes.workspace.installed = [
            AppInfo(bundleID: Self.music, name: "Music"), AppInfo(bundleID: Self.spotify, name: "Spotify"),
            AppInfo(bundleID: "com.apple.finder", name: "Finder"),
            AppInfo(bundleID: "com.apple.systemevents", name: "System Events"),
        ]
        directory.entries = features.map { manifest in
            FeatureEntry(
                manifest: manifest, isEnabled: manifest.isEnabledByDefault,
                context: fakes.context(featureID: manifest.id))
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var dependencies: SettingsDependencies {
        SettingsDependencies(
            services: fakes.services, features: directory, preferences: preferences,
            learning: FakeLearningInspector(settings: fakes.settings), icons: FakeIconProvider(),
            loginItem: FakeLoginItem(), themes: themes, dataDirectory: root.appending(path: "data"),
            about: AboutInfo(version: "1.0"), launcherHotkey: hotkeyStatus, updates: updates,
            permissionWaitsForApp: { permission in
                // Music and Spotify are closed; Finder, the login window and System Events can ask.
                permission == .automation(bundleID: Self.music) || permission == .automation(bundleID: Self.spotify)
            })
    }

    func context() -> SettingsContext {
        let context = SettingsContext(dependencies)
        context.toasts.lifetime = .zero
        return context
    }
}
