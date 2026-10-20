import SwiftUI
import WebKit

/// A transparent `WKWebView` that renders an artifact's HTML document. Used for the
/// HTML / SVG / Mermaid live previews in the artifact panel (§2.4).
struct ArtifactWebView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // Blend with the panel background instead of painting white.
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }

    /// Keeps model-generated previews from navigating out to the network: the initial
    /// in-memory document loads, but any attempt to follow a remote (http/https) link or
    /// redirect is cancelled, so the sandbox can't be used to exfiltrate or phone home.
    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let scheme = navigationAction.request.url?.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

/// Builds the HTML document shown in `ArtifactWebView` for each renderable kind.
enum ArtifactHTML {
    /// `dark` tints the Mermaid theme + body text to match the app theme.
    /// `forExport` swaps the transparent web-view background for a solid one so
    /// standalone exports (file saves, "Open in Browser", PNG capture) render correctly
    /// in any browser/chrome instead of relying on it to supply a background.
    static func document(for artifact: Artifact, dark: Bool, forExport: Bool = false) -> String {
        switch artifact.kind {
        case .html:
            return themedDocument(content: artifact.content, dark: dark, forExport: forExport)
        case .svg:
            return wrap(body: artifact.content, dark: dark, center: true, forExport: forExport)
        case .mermaid:
            return mermaid(artifact.content, dark: dark, forExport: forExport)
        default:
            return wrap(body: "", dark: dark, center: false, forExport: forExport)
        }
    }

    /// HTML artifacts are supposed to be complete documents, but models — especially
    /// smaller/local ones — often emit a bare fragment (plain text or markdown) under
    /// the "html" kind. A fragment has no `<head>` to carry styling, so the browser's
    /// default black text renders straight through to our transparent, often-dark
    /// `WKWebView` background. Route anything without a `<head>` through the same
    /// themed wrapper SVG/Mermaid use; for real documents, inject a zero-specificity
    /// fallback color so any author CSS the model did write still wins.
    private static func themedDocument(content: String, dark: Bool, forExport: Bool = false) -> String {
        guard let headRange = content.range(of: "<head", options: .caseInsensitive),
              let headOpenEnd = content.range(of: ">", range: headRange.upperBound..<content.endIndex) else {
            return wrap(body: content, dark: dark, center: false, forExport: forExport)
        }
        // Zero-specificity fallback: the document's own CSS still wins. For exports,
        // also supply a solid background so a document without one doesn't render dark-
        // mode text against the browser's default white canvas.
        let bg = forExport ? ";background:\(dark ? "#15151a" : "#ffffff")" : ""
        let fallback = "<style>:where(html,body){color:\(dark ? "#e6e6e6" : "#1a1a1a")\(bg)}</style>"
        var result = content
        result.insert(contentsOf: fallback, at: headOpenEnd.upperBound)
        return result
    }

    private static func wrap(body: String, dark: Bool, center: Bool, forExport: Bool = false) -> String {
        let layout = center
            ? "display:flex;align-items:center;justify-content:center;min-height:100vh;"
            : ""
        let bg = forExport ? (dark ? "#15151a" : "#ffffff") : "transparent"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          html,body{margin:0;background:\(bg);\(layout)}
          svg{max-width:100%;height:auto}
          body{color:\(dark ? "#e6e6e6" : "#1a1a1a");font:14px -apple-system,system-ui}
        </style></head><body>\(body)</body></html>
        """
    }

    private static func mermaid(_ source: String, dark: Bool, forExport: Bool = false) -> String {
        // Fail closed: render only with the bundled engine. Never fall back to a remote
        // CDN — that would execute third-party JS and leak a network request from model
        // content if the resource were ever missing.
        guard let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8) else {
            return wrap(body: "<p>Mermaid renderer unavailable.</p>", dark: dark, center: true, forExport: forExport)
        }
        // Escape the diagram source so it can't inject markup/script; Mermaid reads it
        // back as plain text. `securityLevel:'strict'` also sanitizes labels (was 'loose').
        let safeSource = escapeHTML(source)
        let bg = forExport ? (dark ? "#15151a" : "#ffffff") : "transparent"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>html,body{margin:0;background:\(bg);display:flex;justify-content:center}
        .mermaid{max-width:100%}</style></head>
        <body><pre class="mermaid">\(safeSource)</pre>
        <script>\(js)</script>
        <script>mermaid.initialize({startOnLoad:true, theme:'\(dark ? "dark" : "default")', securityLevel:'strict'});</script>
        </body></html>
        """
    }

    /// Minimal HTML-entity escaping for untrusted text interpolated into a document.
    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Renders a renderable artifact's HTML document off-screen and captures it as a PNG —
/// used by the inline card's "Export as PNG" menu item. Drives a throwaway `WKWebView`
/// through load → (Mermaid only) a short settle delay for its JS render → snapshot.
///
/// The web view is hosted in a real, off-screen-positioned `NSWindow` rather than left
/// unparented: an unparented `WKWebView` never commits its compositor output, so
/// `takeSnapshot` silently returns a blank image. Keeps itself alive via `selfRetain`
/// until `completion` fires, since nothing else holds a reference across the async hops.
@MainActor
final class ArtifactPNGRenderer: NSObject, WKNavigationDelegate {
    private let window: NSWindow
    private let webView: WKWebView
    private let needsSettleDelay: Bool
    private let completion: (NSImage?) -> Void
    private var selfRetain: ArtifactPNGRenderer?

    init(artifact: Artifact, dark: Bool, completion: @escaping (NSImage?) -> Void) {
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        webView = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))   // off-screen, never visible
        needsSettleDelay = artifact.kind == .mermaid
        self.completion = completion
        super.init()
        webView.navigationDelegate = self
        selfRetain = self
        window.orderFrontRegardless()
        // The live preview paints its HTML with a transparent background so it blends
        // with the panel behind it — but this capture has no panel behind it, and a
        // WKWebView's default canvas for an unstyled page is opaque white. Left as-is,
        // dark-theme text (chosen to read on a dark backdrop, e.g. #e6e6e6) would render
        // on that white canvas and be nearly invisible. Pass `forExport: true` so the
        // document builder bakes in a matching opaque background.
        let document = ArtifactHTML.document(for: artifact, dark: dark, forExport: true)
        webView.loadHTMLString(document, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (needsSettleDelay ? 0.4 : 0)) { [weak self] in
            self?.snapshot()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    /// Shrinks the view to the content's actual rendered height before capturing, so the
    /// PNG is cropped to the diagram/document instead of padded to the working frame.
    private func snapshot() {
        webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] result, _ in
            guard let self else { return }
            let height = (result as? CGFloat) ?? self.webView.frame.height
            self.webView.setFrameSize(NSSize(width: self.webView.frame.width, height: max(height, 1)))
            let config = WKSnapshotConfiguration()
            config.rect = self.webView.bounds
            self.webView.takeSnapshot(with: config) { image, _ in
                self.finish(image)
            }
        }
    }

    private func finish(_ image: NSImage?) {
        window.orderOut(nil)
        completion(image)
        selfRetain = nil
    }
}
