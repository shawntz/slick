import AppKit
import Host
import Kit
import LauncherUI
import LauncherUITesting

/// Capture sheets of the pages part 2 built: a grid, a list with its detail pane, a streaming
/// detail page, a form with a validation error, Quick Look, the filter dropdown and a notice
/// banner. Each capture shows the panel in the bottom-left corner over a synthetic backdrop and
/// holds key status for about 120 ms plus the capture.
@MainActor enum PagesMode {
    static func run(out: URL, dark: Bool) async -> Bool {
        let world = await DemoWorld()
        let panel = world.panel
        panel.surface.panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        panel.surface.refreshTheme()
        panel.summon()
        await pause(ms: 400)
        panel.dismiss()
        await pause(ms: 150)
        guard let preview = writePreviewImage(to: out.appending(path: "preview/sample-landscape.png")) else {
            say("could not write the preview image")
            return false
        }
        let field = panel.surface.queryField
        func open(_ query: String) async -> Bool {
            world.type(query)
            _ = panel.queryField(field, perform: .submit([]))
            return await waitFor { panel.stack.count == 2 && panel.isIdle }
        }
        let states: [(name: String, caption: String, setUp: @MainActor () async -> Bool)] = [
            (
                "grid", "Grid page",
                {
                    guard await open("photo") else { return false }
                    _ = panel.queryField(field, perform: .moveRight)
                    _ = panel.queryField(field, perform: .moveDown)
                    return (panel.top as? GridPageController)?.grid.selectedIndex == 7
                }
            ),
            (
                "list-detail", "List with detail",
                {
                    guard await open("search notes") else { return false }
                    return await waitFor { ((panel.top as? ListPageController)?.detailLoads ?? 0) > 0 }
                }
            ),
            (
                "streaming", "Streaming detail page",
                {
                    world.type("ask")
                    _ = panel.queryField(field, perform: .submit([]))
                    guard await waitFor({ panel.top is DetailPageController }) else { return false }
                    await pause(ms: 260)
                    return (panel.top as? DetailPageController)?.isStreaming == true
                }
            ),
            (
                "form-error", "Form with a validation error",
                {
                    guard await open("quicklink"), let form = panel.top as? FormPageController else { return false }
                    form.submit()
                    return await waitFor { form.errors["link"] != nil }
                }
            ),
            (
                "quick-look", "Quick Look",
                {
                    panel.quickLook([preview])
                    await pause(ms: 600)
                    return panel.top is QuickLookPageController
                }
            ),
            (
                "filter", "Filter dropdown",
                {
                    guard await open("search files") else { return false }
                    field.openFilterMenu()
                    return panel.surface.overlay != nil
                }
            ),
            (
                "notice", "Notice banner",
                {
                    guard await open("search files") else { return false }
                    return (panel.top as? ListPageController)?.contentView.banner != nil
                }
            ),
        ]
        var cells: [SheetComposer.Cell] = []
        let appearance = dark ? "dark" : "light"
        for state in states {
            var image: CGImage?
            for _ in 0..<2 where image == nil {
                image = await capture(world, state.setUp)
                await pause(ms: 150)
            }
            guard let image else {
                say("capture failed: \(state.name)")
                return false
            }
            cells.append(SheetComposer.Cell(image: image, caption: state.caption))
            try? SheetComposer.writePNG(image, to: out.appending(path: "raw/\(state.name)-\(appearance).png"))
            await pause(ms: 150)
        }
        let rows = [Array(cells.prefix(4)), Array(cells.dropFirst(4))]
        guard let sheet = SheetComposer.compose(title: "Host pages, \(appearance)", rows: rows, scale: 0.5) else {
            return false
        }
        let url = out.appending(path: "sheet-pages-\(appearance).png")
        do {
            try SheetComposer.writePNG(sheet, to: url)
        } catch {
            say("could not write \(url.path): \(error)")
            return false
        }
        say("wrote \(url.path)")
        return true
    }

    /// Shows the panel over a backdrop, sets the state up without key status, then takes key status
    /// for the capture only and hides the panel. Nil when the state did not come up or the field's
    /// text changed while the panel was key.
    private static func capture(_ world: DemoWorld, _ setUp: @MainActor () async -> Bool) async -> CGImage? {
        let panel = world.panel
        let backdrop = BackdropWindow(kind: .busy, frame: world.windowFrame)
        backdrop.orderFrontRegardless()
        backdrop.order(.below, relativeTo: panel.surface.panel.windowNumber)
        defer { backdrop.close() }
        panel.summon()
        defer {
            panel.surface.dismissOverlay()
            panel.dismiss()
            panel.resetToRoot()
        }
        guard await setUp() else { return nil }
        panel.surface.updateHeight(animated: false)
        await pause(ms: 60)
        let text = panel.surface.queryField.text
        panel.surface.panel.makeKey()
        await pause(ms: 120)
        let image = try? await OwnWindowCapture.capture(world.windowFrame)
        return panel.surface.queryField.text == text ? image : nil
    }

    private static func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<150 {
            if condition() { return true }
            await pause(ms: 4)
        }
        return condition()
    }

    /// An invented landscape for Quick Look: sky, sun and hills.
    private static func writePreviewImage(to url: URL) -> URL? {
        let width = 1200
        let height = 800
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let sky = [
            CGColor(srgbRed: 0.98, green: 0.62, blue: 0.38, alpha: 1),
            CGColor(srgbRed: 0.33, green: 0.4, blue: 0.75, alpha: 1),
        ]
        if let gradient = CGGradient(colorsSpace: space, colors: sky as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(
                gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: height), options: [])
        }
        context.setFillColor(CGColor(srgbRed: 1, green: 0.9, blue: 0.55, alpha: 1))
        context.fillEllipse(in: CGRect(x: 760, y: 300, width: 180, height: 180))
        for (index, shade) in [0.32, 0.24, 0.16].enumerated() {
            context.setFillColor(CGColor(srgbRed: shade * 0.6, green: shade + 0.1, blue: shade * 0.8, alpha: 1))
            let base = CGFloat(260 - index * 70)
            context.fillEllipse(in: CGRect(x: CGFloat(index * 300 - 200), y: base - 420, width: 900, height: 600))
        }
        guard let image = context.makeImage() else { return nil }
        do {
            try SheetComposer.writePNG(image, to: url)
        } catch {
            return nil
        }
        return url
    }
}
