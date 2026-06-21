import SwiftUI
import WebKit

/// A transparent `WKWebView` that renders an artifact's HTML document. Used for the
/// HTML / SVG / Mermaid live previews in the artifact panel (§2.4).
struct ArtifactWebView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        // Blend with the panel background instead of painting white.
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
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
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          html,body{margin:0;background:transparent;\(layout)}
          svg{max-width:100%;height:auto}
          body{color:\(dark ? "#e6e6e6" : "#1a1a1a");font:14px -apple-system,system-ui}
        </style></head><body>\(body)</body></html>
        """
    }

    private static func mermaid(_ source: String, dark: Bool) -> String {
        let js = (try? Bundle.main.url(forResource: "mermaid.min", withExtension: "js")
            .map { try String(contentsOf: $0, encoding: .utf8) }) ?? nil
        let script = js.map { "<script>\($0)</script>" }
            ?? "<script src=\"https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js\"></script>"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>html,body{margin:0;background:transparent;display:flex;justify-content:center}
        .mermaid{max-width:100%}</style></head>
        <body><pre class="mermaid">\(source)</pre>
        \(script)
        <script>mermaid.initialize({startOnLoad:true, theme:'\(dark ? "dark" : "default")', securityLevel:'loose'});</script>
        </body></html>
        """
    }
}
