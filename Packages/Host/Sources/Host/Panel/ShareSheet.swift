import AppKit
import Kit

/// The share menu's services: what can share some items, and sharing them.
///
/// The panel shows the services as entries in its action card, so the menu lives inside the panel
/// like every other menu. ``SystemShareSheet`` uses the system's sharing services and is the
/// default in the live app; tests and scenarios pass a fake.
@MainActor public protocol ShareSheet: AnyObject {
    /// The services that can share these items, in the order the menu lists them.
    func options(for items: [ShareItem]) -> [ShareOption]
    /// Shares the items with one of the services ``options(for:)`` returned.
    func share(_ items: [ShareItem], with option: ShareOption)
}

/// One sharing service.
public struct ShareOption: Sendable, Equatable {
    public var id: String
    public var title: String
    /// An SF Symbol name for the entry.
    public var symbolName: String?

    public init(id: String, title: String, symbolName: String? = nil) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
    }
}

/// The system's sharing services: AirDrop, Mail, Messages and the share extensions installed.
@MainActor public final class SystemShareSheet: ShareSheet {
    private var services: [String: NSSharingService] = [:]

    public init() {}

    public func options(for items: [ShareItem]) -> [ShareOption] {
        let objects = Self.objects(items)
        // `sharingServices(forItems:)` is the only way to list services without the system's own
        // menu window, which would take key status from the panel. It is deprecated, so it is
        // reached through the runtime to keep the build free of warnings.
        let selector = NSSelectorFromString("sharingServicesForItems:")
        guard NSSharingService.responds(to: selector),
            let found = NSSharingService.perform(selector, with: objects)?.takeUnretainedValue()
                as? [NSSharingService]
        else { return [] }
        services = [:]
        return found.enumerated().map { index, service in
            let id = "\(index).\(service.title)"
            services[id] = service
            return ShareOption(id: id, title: service.menuItemTitle)
        }
    }

    public func share(_ items: [ShareItem], with option: ShareOption) {
        services[option.id]?.perform(withItems: Self.objects(items))
    }

    private static func objects(_ items: [ShareItem]) -> [Any] {
        items.map { item -> Any in
            switch item {
            case .text(let text): text as NSString
            case .url(let url), .file(let url): url as NSURL
            }
        }
    }
}
