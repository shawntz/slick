import AppKit
import Kit
import LauncherUI
import Quartz

/// Quick Look inside the panel, for Command-Y: a page that previews one file at a time and fills
/// the content area, so the preview keeps the panel's key status and its glass.
///
/// Left and Right step through the files, Command-Y or Escape goes back. The preview view is made
/// by ``PanelController/makePreviewView``, a `QLPreviewView` unless a test replaces it.
@MainActor public final class QuickLookPageController: PageController {
    public let urls: [URL]
    public let contentView = PageContentView()
    /// The file shown now.
    public private(set) var index: Int
    let container = PreviewContainerView()
    private let makePreview: @MainActor (URL) -> NSView
    private weak var host: (any PageHost)?

    public init(urls: [URL], makePreview: @escaping @MainActor (URL) -> NSView) {
        self.urls = urls
        self.makePreview = makePreview
        index = 0
        contentView.show(container)
        showCurrent()
    }

    public var title: String? {
        guard urls.indices.contains(index) else { return nil }
        let name = urls[index].lastPathComponent
        return urls.count > 1 ? HostStrings.previewPosition(name, index + 1, urls.count) : name
    }

    public var searchPlaceholder: String { "" }
    public var query: String { "" }
    /// The file shown now.
    public var url: URL? { urls.indices.contains(index) ? urls[index] : nil }

    public func pageDidAppear(in host: any PageHost) { self.host = host }
    public func pageDidDisappear() {}

    public func pageWillClose() {
        (container.preview as? QLPreviewView)?.close()
    }

    public func queryDidChange(_ text: String) {}
    public func moveSelection(_ move: SelectionMove) -> Bool { false }
    public var target: ActionTarget? { nil }

    public func handle(_ command: QueryCommand) -> Bool {
        switch command {
        case .moveLeft, .moveRight:
            let step = command == .moveLeft ? -1 : 1
            let next = index + step
            guard urls.indices.contains(next) else { return true }
            index = next
            showCurrent()
            host?.pageSelectionDidChange(self)
            return true
        case .chord(let chord) where chord == KeyChord("y", .command):
            host?.popPage(self)
            return true
        default:
            return false
        }
    }

    private func showCurrent() {
        guard let url else { return }
        if let preview = container.preview as? QLPreviewView {
            preview.previewItem = url as NSURL
        } else {
            container.preview = makePreview(url)
        }
    }

    /// The default preview: a `QLPreviewView` with the compact style.
    public static func quickLookView(for url: URL) -> NSView {
        let view = QLPreviewView(frame: .zero, style: .compact) ?? QLPreviewView()
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }
}

/// Holds a preview view and fills the content area with it.
final class PreviewContainerView: NSView, LauncherContentView {
    var contentHeightDidChange: (() -> Void)?
    weak var selectionLens: SelectionLens?

    var preview: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let preview {
                addSubview(preview)
                preview.frame = bounds.insetBy(dx: 12, dy: 8)
            }
        }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func preferredContentHeight(limit: CGFloat) -> CGFloat { limit }
    func apply(_ theme: ResolvedTheme) {}

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        preview?.frame = bounds.insetBy(dx: 12, dy: 8)
    }
}
