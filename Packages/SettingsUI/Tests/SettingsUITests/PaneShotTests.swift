import AppKit
import Foundation
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import LauncherUITesting
import SwiftUI
import Testing

@testable import SettingsUI

/// Renders every pane and every onboarding step in light and dark into offscreen bitmaps, from
/// synthetic features and data. Nothing is shown on screen: the windows are never ordered in.
/// Offscreen bitmaps cannot draw Liquid Glass. The appearance pane's preview shows as a grey box in
/// its shot and the sidebar is left out; the theme sheet composes the preview's real LauncherUI parts
/// over a flat stand-in for the glass instead.
///
/// Set `SETTINGSUI_SHOTS` to a folder to write one PNG sheet per pane there. Without it the test
/// still renders everything and checks that each image has content.
@MainActor @Suite(.timeLimit(.minutes(2))) struct PaneShotTests {
    private static let folder = ProcessInfo.processInfo.environment["SETTINGSUI_SHOTS"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    }

    @Test func rendersEveryPaneInLightAndDark() async throws {
        let bed = try await Self.showcase()
        let model = SettingsModel(dependencies: bed.dependencies)
        model.context.toasts.lifetime = .zero
        await model.learning.load()
        let page = model.features.page("sample")
        await page.appeared()

        let panes: [(String, CGSize, AnyView)] = [
            ("General", CGSize(width: 680, height: 560), AnyView(GeneralPane(model: model.general))),
            ("Appearance", CGSize(width: 760, height: 1480), AnyView(AppearancePane(model: model.appearance))),
            (
                "Root Search", CGSize(width: 680, height: 900),
                AnyView(RootSearchPane(model: model.rootSearch, icons: model.context.icons))
            ),
            (
                "Features", CGSize(width: 680, height: 330),
                AnyView(FeaturesPane(model: model.features, icons: model.context.icons))
            ),
            (
                "Feature page", CGSize(width: 760, height: 1640),
                AnyView(NavigationStack { FeatureDetailPane(model: page, icons: model.context.icons) })
            ),
            ("Permissions", CGSize(width: 680, height: 820), AnyView(PermissionsPane(model: model.permissions))),
            (
                "Learning", CGSize(width: 680, height: 1000),
                AnyView(LearningPane(model: model.learning, icons: model.context.icons))
            ),
            ("Advanced", CGSize(width: 680, height: 560), AnyView(AdvancedPane(model: model.advanced))),
            ("About", CGSize(width: 680, height: 460), AnyView(AboutPane(model: model.about))),
        ]
        for (name, size, view) in panes {
            try write(name, size: size, view)
        }

        // A toast and a hotkey review, as they look over a pane.
        model.general.launcherHotkey.beginRecording()
        model.general.launcherHotkey.handle(key: .l, modifiers: [.control, .option])
        model.context.toasts.show(.success("Applied Classic"))
        try write(
            "General with review and toast", size: CGSize(width: 680, height: 620),
            AnyView(
                GeneralPane(model: model.general).overlay(alignment: .bottom) {
                    ToastBanner(center: model.context.toasts)
                }
            ))
    }

    @Test func rendersEveryOnboardingStep() async throws {
        let bed = try await Self.showcase(permissions: .notDetermined)
        let context = bed.context()
        let model = OnboardingModel(context: context) {}
        var rows: [[SheetComposer.Cell]] = []
        for step in OnboardingModel.Step.allCases {
            var row: [SheetComposer.Cell] = []
            for dark in [false, true] {
                let image = try #require(
                    Self.render(
                        OnboardingView(model: model, toasts: context.toasts), size: CGSize(width: 620, height: 500),
                        dark: dark))
                #expect(Self.hasContent(image))
                row.append(SheetComposer.Cell(image: image, caption: "\(step.title), \(dark ? "dark" : "light")"))
            }
            rows.append(row)
            if step == .permissions { model.skip(.accessibility) }
            model.next()
        }
        if let folder = Self.folder, let sheet = SheetComposer.compose(title: "Onboarding", rows: rows, scale: 0.5) {
            try SheetComposer.writePNG(sheet, to: folder.appending(path: "onboarding.png"))
        }
    }

    @Test func rendersThemePreviewsFromLauncherViews() throws {
        var rows: [[SheetComposer.Cell]] = []
        for named in ThemeStore.builtInThemes {
            var row: [SheetComposer.Cell] = []
            for dark in [false, true] {
                let image = try #require(Self.composePreview(named.theme, dark: dark))
                #expect(Self.hasContent(image))
                row.append(SheetComposer.Cell(image: image, caption: "\(named.name), \(dark ? "dark" : "light")"))
            }
            rows.append(row)
        }
        if let folder = Self.folder,
            let sheet = SheetComposer.compose(title: "Theme preview parts", rows: rows, scale: 0.5)
        {
            try SheetComposer.writePNG(sheet, to: folder.appending(path: "theme-previews.png"))
        }
    }

    /// The preview's field, list and action bar, each drawn by LauncherUI into a bitmap, laid over a
    /// backdrop and a flat stand-in for the glass in the theme's tint.
    static func composePreview(_ theme: Theme, dark: Bool) -> CGImage? {
        _ = NSApplication.shared
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let size = ThemePreviewView.logicalSize(for: theme)
        let view = ThemePreviewView(frame: CGRect(origin: .zero, size: size))
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = view
        defer { window.close() }
        view.apply(theme: theme)
        let resolved = ResolvedTheme(theme: theme, appearance: appearance, accessibility: DisplayAccessibility())
        let scale: CGFloat = 2
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
        }
        // Backdrop.
        let colors = (dark ? [(0.10, 0.12, 0.22), (0.28, 0.12, 0.30)] : [(0.62, 0.78, 0.95), (0.96, 0.76, 0.62)])
            .map { CGColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) }
        if let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
        // Glass stand-in: a frosted base with the theme's tint over it.
        let margin = ThemePreviewView.margin
        let glassRect = CGRect(
            x: margin, y: margin, width: theme.panel.width, height: size.height - margin * 2)
        let radius = CGFloat(theme.panel.cornerRadius)
        context.addPath(
            CGPath(roundedRect: flipped(glassRect), cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(CGColor(gray: dark ? 0.16 : 0.97, alpha: 0.85))
        context.fillPath()
        if let tint = resolved.glassTint {
            context.addPath(
                CGPath(roundedRect: flipped(glassRect), cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor(tint.cgColor)
            context.fillPath()
        }
        // Lens.
        let lensFrame = view.lens.view.frame.offsetBy(dx: margin, dy: margin)
        let lensRadius = CGFloat(theme.lens.cornerRadius)
        context.addPath(
            CGPath(roundedRect: flipped(lensFrame), cornerWidth: lensRadius, cornerHeight: lensRadius, transform: nil))
        context.setFillColor(theme.lens.style == .fill ? resolved.lensFill : resolved.lensGlassTint.cgColor)
        context.fillPath()
        // LauncherUI's own drawing of each part.
        for part in [view.queryField, view.hairline, view.list, view.actionBar] as [NSView] {
            guard let rep = part.bitmapImageRepForCachingDisplay(in: part.bounds) else { continue }
            part.cacheDisplay(in: part.bounds, to: rep)
            guard let image = rep.cgImage else { continue }
            context.draw(image, in: flipped(part.frame.offsetBy(dx: margin, dy: margin)))
        }
        return context.makeImage()
    }

    // MARK: Rendering

    private func write(_ name: String, size: CGSize, _ view: AnyView) throws {
        var cells: [SheetComposer.Cell] = []
        for dark in [false, true] {
            let image = try #require(Self.render(view, size: size, dark: dark), "\(name) did not render")
            #expect(Self.hasContent(image), "\(name) rendered blank")
            cells.append(SheetComposer.Cell(image: image, caption: dark ? "Dark" : "Light"))
        }
        guard let folder = Self.folder,
            let sheet = SheetComposer.compose(title: "Settings: \(name)", rows: [cells], scale: 0.5)
        else { return }
        let file = name.lowercased().replacingOccurrences(of: " ", with: "-") + ".png"
        try SheetComposer.writePNG(sheet, to: folder.appending(path: file))
    }

    /// Draws a view into a bitmap through a window that is never ordered in.
    static func render<V: View>(_ view: V, size: CGSize, dark: Bool) -> CGImage? {
        _ = NSApplication.shared
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height).background(
                Color(nsColor: .windowBackgroundColor)))
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
        // Layers that were never displayed draw blank in a bitmap, so display them first.
        hosting.display()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep.cgImage
    }

    /// True when the image is not one flat colour.
    static func hasContent(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        let length = CFDataGetLength(data)
        let stride = max(4, (length / 4000) / 4 * 4)
        let first = (bytes[0], bytes[1], bytes[2])
        var offset = 0
        while offset + 2 < length {
            if (bytes[offset], bytes[offset + 1], bytes[offset + 2]) != first { return true }
            offset += stride
        }
        return false
    }

    // MARK: Data

    /// A test bed with made-up history, favorites, hotkeys, a user theme and mixed permissions.
    static func showcase(permissions: PermissionStatus = .granted) async throws -> TestBed {
        let bed = TestBed(permissions: permissions)
        if permissions == .granted {
            bed.fakes.permissions.set(.inputMonitoring, to: .notDetermined)
            bed.fakes.permissions.set(.screenRecording, to: .denied)
        }
        let notes = ItemID("app", "com.example.notes")
        let terminal = ItemID("app", "com.example.terminal")
        bed.lookUp[notes] = Row(id: notes, title: "Example Notes", icon: .symbol("note.text", tint: .yellow))
        bed.lookUp[terminal] = Row(id: terminal, title: "Example Terminal", icon: .symbol("terminal", tint: .gray))
        bed.preferences.setFavorites([notes, TestBed.list, terminal])
        bed.preferences.setAlias("os", for: TestBed.open)
        try bed.preferences.setHotkey(KeyCombo(.l, [.control, .option]), for: TestBed.list)
        bed.general[HostSettings.fallbackCommands] = [TestBed.open.rawValue, TestBed.show.rawValue]
        bed.general[HostSettings.tabCommand] = TestBed.open.rawValue
        bed.sampleSettings()[SampleSettings.ignored] = ["draft", "scratch"]
        bed.sampleSettings()[SampleSettings.groups] = ["work"]
        bed.fakes.workspace.installed = [AppInfo(bundleID: "com.example.writer", name: "Example Writer")]
        bed.sampleSettings()[SampleSettings.editor] = "com.example.writer"
        try await bed.fakes.secrets.setSecret("synthetic", for: "sample.token")
        try bed.themes.save(.graphite, as: "Night Shift")
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        bed.learning.items = [
            LearnedItem(
                id: terminal, title: "Example Terminal", icon: .symbol("terminal"), useCount: 41, lastUsed: day),
            LearnedItem(id: notes, title: "Example Notes", icon: .symbol("note.text"), useCount: 17, lastUsed: day),
            LearnedItem(
                id: TestBed.open, title: "Open Sample", useCount: 6, lastUsed: day.addingTimeInterval(-90 * 86_400)),
        ]
        bed.learning.learnedQueries = [
            LearnedQuery(query: "ter", items: [.init(id: terminal, title: "Example Terminal", weight: 2.6)]),
            LearnedQuery(query: "no", items: [.init(id: notes, title: "Example Notes", weight: 1.4)]),
            LearnedQuery(
                query: "op",
                items: [
                    .init(id: TestBed.open, title: "Open Sample", weight: 0.9),
                    .init(id: notes, title: "Example Notes", weight: 0.3),
                ]),
        ]
        return bed
    }
}
