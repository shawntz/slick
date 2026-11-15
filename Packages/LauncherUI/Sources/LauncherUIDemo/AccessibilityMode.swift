import AppKit
import ApplicationServices
import LauncherUI
import LauncherUITesting

/// Reads the panel through the `AXUIElement` API, in process, as an accessibility client would.
/// Accessibility on one's own windows needs no permission. The panel is shown without key
/// status for a moment, because a dismissed panel is hidden from accessibility.
enum AccessibilityMode {
    static func run(_ options: DemoOptions) async -> Bool {
        let scene = DemoScene()
        scene.summoner.prewarm()
        var activated: [Int] = []
        scene.list.onActivate = { activated.append($0) }
        scene.list.select(1, animated: false)
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 2)
        let hiddenList = list(in: app)
        scene.summoner.takesKeyStatus = false
        scene.summoner.summon()
        await pause(ms: 100)
        defer { scene.summoner.dismiss(returnFocus: false) }

        var checks: [(String, Bool)] = [("a dismissed panel exposes no list", hiddenList == nil)]
        guard let axList = list(in: app) else {
            say("no AXList found under the app's windows")
            return false
        }
        let items = children(axList)
        checks.append(("11 children: 2 headers, 9 rows", items.count == 11))
        if items.count == 11 {
            checks.append(
                (
                    "header role and label",
                    string(items[0], kAXRoleAttribute) == kAXStaticTextRole
                        && string(items[0], kAXDescriptionAttribute) == "Suggested"
                ))
            checks.append(
                (
                    "row role and label",
                    string(items[1], kAXRoleAttribute) == kAXButtonRole
                        && string(items[1], kAXDescriptionAttribute) == "Aurora Notes, Application"
                ))
            checks.append(("selected row", value(items[2], kAXSelectedAttribute) as? Bool == true))
            checks.append(
                (
                    "press activates",
                    AXUIElementPerformAction(items[3], kAXPressAction as CFString) == .success
                        && activated == [2]
                ))
        }
        if let field = find(role: kAXTextFieldRole, under: app) {
            checks.append(("query field is a search field", string(field, kAXSubroleAttribute) == "AXSearchField"))
        }
        for (name, passed) in checks { say("\(passed ? "ok  " : "FAIL") \(name)") }
        return checks.allSatisfy(\.1)
    }

    private static func list(in app: AXUIElement) -> AXUIElement? { find(role: kAXListRole, under: app) }

    private static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? { value(element, name) as? String }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func find(role: String, under element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        if string(element, kAXRoleAttribute) == role { return element }
        guard depth < 14 else { return nil }
        let next = depth == 0 ? ((value(element, kAXWindowsAttribute) as? [AXUIElement]) ?? []) : children(element)
        for child in next {
            if let found = find(role: role, under: child, depth: depth + 1) { return found }
        }
        return nil
    }
}
