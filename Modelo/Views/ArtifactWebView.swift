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
        // Only on a new document: SwiftUI calls this on every parent re-render (~20×/s
        // while a reply streams), and reloading wiped whatever the user was doing.
        if context.coordinator.shouldLoad(html) {
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    /// Keeps model-generated previews from navigating out to the network: the initial
    /// in-memory document loads, but any attempt to follow a remote (http/https) link or
    /// redirect is cancelled, so the sandbox can't be used to exfiltrate or phone home.
    /// Also tracks which document is loaded, so re-renders don't reload it.
    final class Coordinator: NSObject, WKNavigationDelegate {
        private var loadedHTML: String?

        /// True (and recorded) when `html` isn't the document already showing.
        func shouldLoad(_ html: String) -> Bool {
            guard html != loadedHTML else { return false }
            loadedHTML = html
            return true
        }

        /// Makes the next `shouldLoad` true again (e.g. after the web engine died).
        func forgetLoadedDocument() { loadedHTML = nil }

        /// The page's web process died (memory pressure, a runaway script): reload the
        /// same document rather than leave a blank preview until the panel is reopened.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard let html = loadedHTML else { return }
            forgetLoadedDocument()
            if shouldLoad(html) { webView.loadHTMLString(html, baseURL: nil) }
        }

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
        \(forExport ? "" : panZoom(dark: dark))
        </body></html>
        """
    }

    /// Zoom/pan for the live Mermaid preview: dense graphs shrink to fit the panel and
    /// their labels become unreadable. Pinch or ⌘/⌃-scroll zooms about the cursor,
    /// scroll or drag pans, and corner buttons cover mouse users (⤢ refits).
    /// The diagram opens fitted whole and centered, and refits when the panel resizes.
    /// Exports skip it: the PNG renderer measures the page's natural scroll height.
    private static func panZoom(dark: Bool) -> String {
        let (bg, fg, line) = dark ? ("#2a2a31", "#e6e6e6", "#3a3a42") : ("#f2f2f4", "#1a1a1a", "#d0d0d6")
        return """
        <style>
          /* The script places the diagram itself, so take it out of the base template's
             flex layout: pinned at the origin, at its natural size, clipped at the panel. */
          html{overflow:hidden}
          html,body{width:100%;height:100%;display:block}
          .mermaid{position:absolute;left:0;top:0;margin:0;transform-origin:0 0;
            cursor:grab;user-select:none;-webkit-user-select:none}
          .mermaid svg{display:block;max-width:none!important}
          .mermaid.drag{cursor:grabbing}
          #zoom{position:fixed;top:8px;right:8px;display:flex;gap:4px}
          #zoom button{width:26px;height:24px;border:1px solid \(line);border-radius:6px;
            background:\(bg);color:\(fg);font:13px -apple-system,system-ui;cursor:pointer}
        </style>
        <div id="zoom"><button data-z="0.8" title="Zoom out">−</button><button data-z="0" title="Fit">⤢</button><button data-z="1.25" title="Zoom in">+</button></div>
        <script>
        (() => {
          const el = document.querySelector('.mermaid');
          let s = 1, x = 0, y = 0, f = 1, pinching = false, drag = null;
          const apply = () => { el.style.transform = `translate(${x}px,${y}px) scale(${s})`; };
          // Show the whole diagram centered, never enlarged past 100%. Mermaid draws it
          // width="100%" (fill the container), so pin it to its viewBox size first.
          const fit = () => {
            const vb = el.querySelector('svg')?.viewBox.baseVal; if (!vb?.width) return;
            const svg = el.querySelector('svg');
            svg.setAttribute('width', vb.width); svg.setAttribute('height', vb.height);
            const pad = 16;
            f = s = Math.min(1, (innerWidth - 2 * pad) / vb.width, (innerHeight - 2 * pad) / vb.height);
            x = (innerWidth - vb.width * s) / 2; y = (innerHeight - vb.height * s) / 2; apply();
          };
          // Mermaid renders asynchronously after load, inserting the <svg> before it measures
          // the drawing and sets its viewBox; fit once that size exists.
          const obs = new MutationObserver(() => {
            if (el.querySelector('svg')?.viewBox.baseVal.width) { obs.disconnect(); fit(); }
          });
          obs.observe(el, { childList: true, subtree: true, attributes: true, attributeFilter: ['viewBox'] });
          addEventListener('resize', fit);
          // Scale by k, keeping the point under (cx, cy) fixed on screen.
          const zoom = (k, cx, cy) => {
            const n = Math.min(8, Math.max(Math.min(0.2, f), s * k)); k = n / s;
            x = cx - k * (cx - x); y = cy - k * (cy - y); s = n; apply();
          };
          addEventListener('wheel', e => {
            e.preventDefault();
            // WebKit may report a trackpad pinch as ctrl+wheel; skip it if gesture events already handle it.
            if (e.ctrlKey || e.metaKey) { if (!pinching) zoom(Math.exp(-e.deltaY / 100), e.clientX, e.clientY); }
            else { x -= e.deltaX; y -= e.deltaY; apply(); }
          }, { passive: false });
          let g = 1;   // gesturechange's scale is cumulative; zoom by the step since the last event
          addEventListener('gesturestart', e => { e.preventDefault(); pinching = true; g = 1; });
          addEventListener('gesturechange', e => { e.preventDefault(); zoom(e.scale / g, e.clientX, e.clientY); g = e.scale; });
          addEventListener('gestureend', e => { e.preventDefault(); pinching = false; });
          el.addEventListener('mousedown', e => { e.preventDefault(); drag = [e.clientX - x, e.clientY - y]; el.classList.add('drag'); });
          addEventListener('mousemove', e => { if (drag) { x = e.clientX - drag[0]; y = e.clientY - drag[1]; apply(); } });
          addEventListener('mouseup', () => { drag = null; el.classList.remove('drag'); });
          document.getElementById('zoom').addEventListener('click', e => {
            const z = Number(e.target.dataset.z);
            if (Number.isNaN(z)) return;   // click landed in the gap between buttons
            // Zoom about the middle of the diagram's on-screen part, so it stays in view after a pan.
            const r = (el.querySelector('svg') || el).getBoundingClientRect();
            const cx = (Math.max(r.left, 0) + Math.min(r.right, innerWidth)) / 2;
            const cy = (Math.max(r.top, 0) + Math.min(r.bottom, innerHeight)) / 2;
            if (z) zoom(z, cx, cy); else fit();
          });
        })();
        </script>
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

    /// Resizes the view to the content before capturing, so the PNG is cropped to the
    /// diagram/document instead of padded to the working frame. Mermaid draws its SVG
    /// width="100%", which squeezed wide diagrams into the 1000pt frame; pin it to its
    /// natural (viewBox) size and widen the frame to match. Other kinds keep 1000pt.
    private func snapshot() {
        let pinMermaid = """
        (() => { const s = document.querySelector('.mermaid svg'); if (!s) return 0;
          const vb = s.viewBox.baseVal; s.setAttribute('width', vb.width); s.setAttribute('height', vb.height);
          s.style.maxWidth = 'none'; return vb.width; })()
        """
        webView.evaluateJavaScript(pinMermaid) { [weak self] result, _ in
            guard let self else { return }
            if let width = result as? CGFloat, width > 0 {
                self.webView.setFrameSize(NSSize(width: ceil(width) + 48, height: self.webView.frame.height))
            }
            self.webView.evaluateJavaScript("document.body.scrollHeight") { result, _ in
                let height = (result as? CGFloat) ?? self.webView.frame.height
                self.webView.setFrameSize(NSSize(width: self.webView.frame.width, height: max(height, 1)))
                let config = WKSnapshotConfiguration()
                config.rect = self.webView.bounds
                self.webView.takeSnapshot(with: config) { image, _ in
                    self.finish(image)
                }
            }
        }
    }

    private func finish(_ image: NSImage?) {
        window.orderOut(nil)
        completion(image)
        selfRetain = nil
    }
}
