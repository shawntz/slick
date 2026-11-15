import AppKit
import Host
import LauncherUI
import LauncherUITesting

/// Capture sheets of the real panel: root with results, the action panel, a toast, the confirm card
/// and a pushed list page. Each capture shows the panel with key status for about a quarter of a
/// second over a synthetic backdrop, in a screen corner.
@MainActor enum ShotsMode {
    static func run(out: URL, dark: Bool) async -> Bool {
        let world = await DemoWorld()
        let panel = world.panel
        panel.surface.panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        panel.surface.refreshTheme()
        // The glass finishes an appearance change only after it has been on screen for a moment.
        panel.summon()
        await pause(ms: 400)
        panel.dismiss()
        await pause(ms: 150)
        let field = panel.surface.queryField
        let states: [(name: String, caption: String, setUp: @MainActor () async -> Bool)] = [
            (
                "root", "Root with results",
                {
                    world.type("e")
                    return panel.rootPage.list.content.rowCount > 0
                }
            ),
            (
                "actions", "Action panel",
                {
                    world.type("proj")
                    panel.openActionPanel()
                    return panel.surface.overlay === panel.actionCard
                }
            ),
            (
                "toast", "Toast",
                {
                    world.type("copy sample")
                    _ = panel.queryField(field, perform: .submit([]))
                    return await waitFor { panel.surface.actionBar.toast != nil }
                }
            ),
            (
                "confirm", "Confirm card",
                {
                    world.type("clear")
                    _ = panel.queryField(field, perform: .submit([]))
                    return await waitFor { panel.pendingCard != nil }
                }
            ),
            (
                "list", "Pushed list page",
                {
                    world.type("clipboard")
                    _ = panel.queryField(field, perform: .submit([]))
                    guard await waitFor({ (panel.top as? ListPageController)?.loadCount == 1 }) else { return false }
                    _ = panel.queryField(field, perform: .moveDown)
                    return true
                }
            ),
        ]
        var cells: [SheetComposer.Cell] = []
        let appearance = dark ? "dark" : "light"
        for state in states {
            var image: CGImage?
            // A key press from the person at the keyboard can land in the field while the panel is
            // key; such a capture is retried once.
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
        let rows = [Array(cells.prefix(3)), Array(cells.dropFirst(3))]
        guard let sheet = SheetComposer.compose(title: "Host panel, \(appearance)", rows: rows, scale: 0.5) else {
            return false
        }
        let url = out.appending(path: "sheet-host-\(appearance).png")
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
    /// for the capture only, and hides the panel. Nil when the state did not come up or the field's
    /// text changed while the panel was key.
    private static func capture(_ world: DemoWorld, _ setUp: @MainActor () async -> Bool) async -> CGImage? {
        let panel = world.panel
        let backdrop = BackdropWindow(kind: .busy, frame: world.windowFrame)
        backdrop.orderFrontRegardless()
        backdrop.order(.below, relativeTo: panel.surface.panel.windowNumber)
        defer { backdrop.close() }
        panel.summon()
        defer { panel.dismiss() }
        guard await setUp() else { return nil }
        panel.surface.updateHeight(animated: false)
        let text = panel.top.query
        panel.surface.panel.makeKey()
        await pause(ms: 120)
        let image = try? await OwnWindowCapture.capture(world.windowFrame)
        return panel.top.query == text ? image : nil
    }

    private static func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<60 {
            if condition() { return true }
            await pause(ms: 2)
        }
        return condition()
    }
}
