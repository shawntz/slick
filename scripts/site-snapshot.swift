// Loads a web page in an offscreen WKWebView and writes it as a PNG, so the website can be checked
// at any width and appearance without opening a browser. No window is ever shown.
//
//   swift scripts/site-snapshot.swift <url> <out.png> [options]
//
//   --width <points>          viewport width, default 1440
//   --height <points>         viewport height, default 900. With --full the page sets the height
//   --appearance dark|light   the appearance the page sees through prefers-color-scheme, default dark
//   --scale <n>               pixels per point in the PNG, default 1
//   --full                    capture the whole page instead of the first viewport
//   --settle <seconds>        wait after load before capturing, default 0.5
//
// Serve the page from a local server, for example `python3 -m http.server -b 127.0.0.1 8765 -d site`.
// Lazy images are switched to eager before capture, so a full-page shot has every picture in it.
// For a picture that must not fall back to the system font, give the page an explicit font family.
import AppKit
import WebKit

struct Options {
    var url: URL
    var output: URL
    var width: CGFloat = 1440
    var height: CGFloat = 900
    var dark = true
    var scale: CGFloat = 1
    var full = false
    var settle: TimeInterval = 0.5
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("site-snapshot: \(message)\n".utf8))
    exit(1)
}

func parseOptions() -> Options {
    var args = Array(CommandLine.arguments.dropFirst())
    let usage = "usage: site-snapshot <url> <out.png> [--width n] [--height n] [--appearance dark|light] [--scale n] [--full] [--settle s]"
    guard args.count >= 2, let url = URL(string: args[0]) else { fail(usage) }
    var options = Options(url: url, output: URL(fileURLWithPath: args[1]))
    args.removeFirst(2)
    func value(_ name: String) -> String {
        guard !args.isEmpty else { fail("\(name) needs a value") }
        return args.removeFirst()
    }
    func number(_ name: String) -> Double {
        guard let n = Double(value(name)), n > 0 else { fail("\(name) needs a positive number") }
        return n
    }
    while !args.isEmpty {
        let name = args.removeFirst()
        switch name {
        case "--width": options.width = CGFloat(number(name))
        case "--height": options.height = CGFloat(number(name))
        case "--scale": options.scale = CGFloat(number(name))
        case "--settle": options.settle = number(name)
        case "--full": options.full = true
        case "--appearance":
            switch value(name) {
            case "dark": options.dark = true
            case "light": options.dark = false
            default: fail("--appearance is dark or light")
            }
        default: fail("unknown option \(name)\n\(usage)")
        }
    }
    return options
}

// Runs inside the page once it has loaded: make lazy images load, then wait for fonts and images.
let prepareScript = """
    document.querySelectorAll('img[loading="lazy"]').forEach((img) => { img.loading = 'eager'; });
    await document.fonts.ready;
    await Promise.all(Array.from(document.images).map((img) => img.complete ? null :
        new Promise((done) => { img.addEventListener('load', done); img.addEventListener('error', done); })));
    return Math.ceil(document.documentElement.scrollHeight);
    """

@MainActor
final class Snapshotter: NSObject, WKNavigationDelegate {
    let options: Options
    let webView: WKWebView

    init(options: Options) {
        self.options = options
        let configuration = WKWebViewConfiguration()
        // Nothing the page stores outlives this process.
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: options.width, height: options.height),
            configuration: configuration)
        super.init()
        webView.appearance = NSAppearance(named: options.dark ? .darkAqua : .aqua)
        webView.navigationDelegate = self
    }

    func start() {
        webView.load(URLRequest(url: options.url, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await capture() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        fail("load failed: \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        fail("load failed: \(error.localizedDescription)")
    }

    func capture() async {
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(
                prepareScript, arguments: [:], in: nil, contentWorld: .page)
        } catch {
            fail("page script failed: \(error.localizedDescription)")
        }
        if options.full, let height = (result as? NSNumber)?.doubleValue, height > 0 {
            webView.setFrameSize(CGSize(width: options.width, height: CGFloat(height)))
        }
        try? await Task.sleep(for: .seconds(options.settle))

        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        configuration.snapshotWidth = NSNumber(value: Double(options.width))
        let image: NSImage
        do {
            image = try await webView.takeSnapshot(configuration: configuration)
        } catch {
            fail("snapshot failed: \(error.localizedDescription)")
        }
        write(image)
        exit(0)
    }

    func write(_ image: NSImage) {
        let pixelsWide = Int((webView.bounds.width * options.scale).rounded())
        let pixelsHigh = Int((webView.bounds.height * options.scale).rounded())
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { fail("could not make a \(pixelsWide) by \(pixelsHigh) bitmap") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fail("could not encode the PNG")
        }
        do {
            try png.write(to: options.output, options: .atomic)
        } catch {
            fail("could not write \(options.output.path): \(error.localizedDescription)")
        }
        print("site-snapshot: \(options.output.path) \(pixelsWide)x\(pixelsHigh)")
    }
}

let options = parseOptions()
MainActor.assumeIsolated {
    let app = NSApplication.shared
    // No Dock icon, no menu bar, no activation: the process never shows anything.
    app.setActivationPolicy(.prohibited)
    let snapshotter = Snapshotter(options: options)
    snapshotter.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { fail("timed out after 60 seconds") }
    app.run()
    withExtendedLifetime(snapshotter) {}
}
