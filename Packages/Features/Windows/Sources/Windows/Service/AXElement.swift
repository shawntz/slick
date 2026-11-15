import ApplicationServices
import Foundation

/// A thin, typed layer over one Accessibility element. Every call is synchronous inter-process
/// messaging, so only ``AccessibilityWindows`` calls these, and only from its background queue.
///
/// Errors map to ``WindowError``: a disabled API means Accessibility is not granted, an invalid
/// element means the window or its app went away, and an app that does not answer in time refused.
/// None of these calls can show a permission prompt.
nonisolated struct AXElement: @unchecked Sendable {
    // AXUIElement is an immutable reference that the system lets any thread use.
    let element: AXUIElement

    /// How long one call may wait for an app before it counts as refused. A hung app cannot stall
    /// a command for longer.
    static let messagingTimeout: Float = 0.5

    init(_ element: AXUIElement) {
        self.element = element
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
    }

    /// The element of a running app.
    static func application(_ process: pid_t) -> AXElement {
        AXElement(AXUIElementCreateApplication(process))
    }

    /// A token that stays the same for one window while it is open: the element's hash, which the
    /// system derives from the window's identity.
    var token: Int { Int(bitPattern: CFHash(element)) }

    // MARK: - Reading

    func value(_ attribute: String) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        switch error {
        case .success: return value
        case .noValue, .attributeUnsupported, .notImplemented: return nil
        default: throw Self.failure(error)
        }
    }

    func element(_ attribute: String) throws -> AXElement? {
        guard let value = try value(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // The type ID was checked on the line above.
        return AXElement(unsafeDowncast(value, to: AXUIElement.self))
    }

    func elements(_ attribute: String) throws -> [AXElement] {
        guard let value = try value(attribute), let array = value as? [AnyObject] else { return [] }
        return array.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            return AXElement(unsafeDowncast(item, to: AXUIElement.self))
        }
    }

    func string(_ attribute: String) throws -> String? {
        try value(attribute) as? String
    }

    func bool(_ attribute: String) throws -> Bool? {
        guard let value = try value(attribute), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }

    func isSettable(_ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return error == .success && settable.boolValue
    }

    /// The window's frame in the Accessibility space, or nil when it has no position or size.
    func frame() throws -> Frame? {
        guard let position = try value(kAXPositionAttribute), let size = try value(kAXSizeAttribute),
            CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
            AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent)
        else { return nil }
        return Frame(x: point.x, y: point.y, width: extent.width, height: extent.height)
    }

    // MARK: - Changing

    func set(_ attribute: String, _ value: CFTypeRef) throws {
        let error = AXUIElementSetAttributeValue(element, attribute as CFString, value)
        guard error == .success else { throw Self.failure(error) }
    }

    func set(_ attribute: String, _ value: Bool) throws {
        try set(attribute, (value ? kCFBooleanTrue : kCFBooleanFalse) as CFBoolean)
    }

    func perform(_ action: String) throws {
        let error = AXUIElementPerformAction(element, action as CFString)
        guard error == .success else { throw Self.failure(error) }
    }

    /// Sets a window's frame and returns the frame it took.
    ///
    /// The size goes first, then the position, then the size again: a window moving to a smaller
    /// display may be clamped by the old one until it has moved. Apps that animate frame changes
    /// for assistive apps do so only while `AXEnhancedUserInterface` is on, so it is off for the
    /// move and restored after.
    func setFrame(_ frame: Frame, canResize: Bool, app: AXElement) throws -> Frame {
        let enhanced = (try? app.bool("AXEnhancedUserInterface")) ?? false
        if enhanced { try? app.set("AXEnhancedUserInterface", false) }
        defer {
            if enhanced { try? app.set("AXEnhancedUserInterface", true) }
        }
        var size = CGSize(width: frame.width, height: frame.height)
        var origin = CGPoint(x: frame.x, y: frame.y)
        guard let sizeValue = AXValueCreate(.cgSize, &size), let originValue = AXValueCreate(.cgPoint, &origin) else {
            throw WindowError.refused
        }
        // A window that refuses a size keeps its own. The caller settles its position from the frame
        // read back.
        if canResize { try? set(kAXSizeAttribute, sizeValue) }
        try set(kAXPositionAttribute, originValue)
        if canResize { try? set(kAXSizeAttribute, sizeValue) }
        guard let actual = try self.frame() else { throw WindowError.windowGone }
        return actual
    }

    // MARK: - Errors

    static func failure(_ error: AXError) -> WindowError {
        switch error {
        case .apiDisabled: .accessibilityMissing
        case .invalidUIElement: .windowGone
        default: .refused
        }
    }
}
