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
    static func document(for artifact: Artifact, dark: Bool) -> String {
        switch artifact.kind {
        case .html:
            // HTML artifacts are usually complete documents; render as-is.
            return artifact.content
        case .svg:
            return wrap(body: artifact.content, dark: dark, center: true)
        case .mermaid:
            return mermaid(artifact.content, dark: dark)
        default:
            return wrap(body: "", dark: dark, center: false)
        }
    }

    private static func wrap(body: String, dark: Bool, center: Bool) -> String {
        let layout = center
            ? "display:flex;align-items:center;justify-content:center;min-height:100vh;"
            : ""
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          html,body{margin:0;background:transparent;\(layout)}
          svg{max-width:100%;height:auto}
          body{color:\(dark ? "#e6e6e6" : "#1a1a1a");font:14px -apple-system,system-ui}
        </style></head><body>\(body)</body></html>
        """
    }

    private static func mermaid(_ source: String, dark: Bool) -> String {
        // Fail closed: render only with the bundled engine. Never fall back to a remote
        // CDN — that would execute third-party JS and leak a network request from model
        // content if the resource were ever missing.
        guard let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8) else {
            return wrap(body: "<p>Mermaid renderer unavailable.</p>", dark: dark, center: true)
        }
        // Escape the diagram source so it can't inject markup/script; Mermaid reads it
        // back as plain text. `securityLevel:'strict'` also sanitizes labels (was 'loose').
        let safeSource = escapeHTML(source)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>html,body{margin:0;background:transparent;display:flex;justify-content:center}
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
