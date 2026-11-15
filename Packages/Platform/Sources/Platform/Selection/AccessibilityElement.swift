import ApplicationServices
import Foundation

/// One element of an app's accessibility tree, as far as the selection reader needs it. ``AXElement``
/// is the live one; tests build trees of fakes.
nonisolated public protocol AccessibilityElement: Sendable {
    /// The value of an attribute, such as `AXSelectedText`, or nil when the element has none.
    func value(of attribute: String) -> AccessibilityValue?
}

/// An attribute value the selection reader understands.
nonisolated public enum AccessibilityValue: Sendable {
    case text(String)
    case url(URL)
    case element(any AccessibilityElement)
    case elements([any AccessibilityElement])
}

/// An element of a real app, through the Accessibility API. Reading another app's elements needs
/// the Accessibility permission; without it every read fails, and none prompts. Each element gives
/// up on an app that does not answer within ``messagingTimeout``.
nonisolated public struct AXElement: AccessibilityElement, @unchecked Sendable {
    /// How long a read waits for a busy app.
    public static let messagingTimeout: Float = 0.25

    /// The element. `AXUIElement` calls may come from any thread.
    public let element: AXUIElement

    public init(_ element: AXUIElement) {
        self.element = element
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
    }

    /// The focused element of the app with this process ID, or nil when it has none or cannot be
    /// read.
    public static func focusedElement(ofProcess processID: pid_t) -> AXElement? {
        let application = AXElement(AXUIElementCreateApplication(processID))
        guard case .element(let focused)? = application.value(of: kAXFocusedUIElementAttribute) else { return nil }
        return focused as? AXElement
    }

    public func value(of attribute: String) -> AccessibilityValue? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success, let raw else {
            return nil
        }
        return Self.convert(raw)
    }

    /// The reader's form of an attribute value, or nil for a type it does not use.
    static func convert(_ value: CFTypeRef) -> AccessibilityValue? {
        let type = CFGetTypeID(value)
        if type == CFStringGetTypeID() { return .text(value as! String) }
        if type == CFURLGetTypeID() { return .url(value as! URL) }
        if type == AXUIElementGetTypeID() { return .element(AXElement(value as! AXUIElement)) }
        if type == CFArrayGetTypeID() {
            let items = value as! [CFTypeRef]
            let elements = items.compactMap { item -> (any AccessibilityElement)? in
                CFGetTypeID(item) == AXUIElementGetTypeID() ? AXElement(item as! AXUIElement) : nil
            }
            return .elements(elements)
        }
        return nil
    }
}
